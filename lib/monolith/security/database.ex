defmodule Monolith.Security.Database do
  @moduledoc "SQLCipher-only protected database infrastructure and cross-process vault exclusion."

  alias Exqlite.Sqlite3
  alias Monolith.Security.{CipherKey, Keychain}

  @supported_version "4.20.0"
  @runtime_lock ".runtime-lock.sqlite3"

  def supported_version, do: @supported_version

  if Mix.env() == :test do
    def managed?, do: Application.get_env(:monolith, :vault_managed, false)
  else
    def managed?, do: true
  end

  def repo_options(key) do
    [
      key: CipherKey.new!(key),
      temp_store: :memory,
      secure_delete: :on,
      synchronous: :full,
      log: false,
      telemetry_event: nil,
      custom_pragmas: [cipher_plaintext_header_size: 0, cipher_memory_security: "ON"]
    ]
  end

  def migration_pending? do
    root = Keychain.directory()

    case File.lstat(Path.join(root, ".migration-pending")) do
      {:error, :enoent} ->
        migration_journal_pending?(Path.join([root, "migration", "state.json"]))

      _ ->
        true
    end
  end

  # Only the configured vault root plus fixed migration/state.json reaches this
  # helper; HTTP/provider values cannot select its path. Unreadable journals fence startup.
  # sobelow_skip ["Traversal.FileModule"]
  defp migration_journal_pending?(path) do
    case File.read(path) do
      {:error, :enoent} -> false
      {:ok, json} -> not match?({:ok, %{"phase" => "complete"}}, Jason.decode(json))
      _ -> true
    end
  end

  def validate do
    with {:ok, %{rows: [[version]]}} <-
           Monolith.Repo.query("PRAGMA cipher_version", [], log: false, telemetry_event: nil),
         true <- supported_version?(version),
         {:ok, %{rows: [[count]]}} when is_integer(count) <-
           Monolith.Repo.query("SELECT count(*) FROM sqlite_schema", [],
             log: false,
             telemetry_event: nil
           ),
         {:ok, %{rows: [[header_size]]}} when header_size in [0, "0"] <-
           Monolith.Repo.query("PRAGMA cipher_plaintext_header_size", [],
             log: false,
             telemetry_event: nil
           ) do
      :ok
    else
      _ -> {:error, :database_unavailable}
    end
  rescue
    _ -> {:error, :database_unavailable}
  catch
    _, _ -> {:error, :database_unavailable}
  end

  def migrate do
    Ecto.Migrator.run(Monolith.Repo, Application.app_dir(:monolith, "priv/repo/migrations"), :up,
      all: true,
      log: false,
      log_migrations_sql: false,
      log_migrator_sql: false
    )

    :ok
  rescue
    _ -> {:error, :migration_failed}
  catch
    _, _ -> {:error, :migration_failed}
  end

  # The fixed empty sidecar contains no application data. Never unlink it: doing
  # so would allow two processes to lock different inodes at the same pathname.
  # sobelow_skip ["Traversal.FileModule"]
  def acquire_runtime_lock do
    directory = Keychain.directory()
    path = Path.join(directory, @runtime_lock)

    with :ok <- private_directory(directory),
         :ok <- create_private_file(path),
         {:ok, handle} <- Sqlite3.open(path, mode: :readwrite) do
      lock_runtime_handle(handle)
    else
      _ -> {:error, :vault_in_use}
    end
  rescue
    _ -> {:error, :vault_in_use}
  end

  defp lock_runtime_handle(handle) do
    with :ok <- Sqlite3.set_busy_timeout(handle, 1_000),
         :ok <- Sqlite3.execute(handle, "BEGIN EXCLUSIVE") do
      {:ok, handle}
    else
      _ ->
        Sqlite3.close(handle)
        {:error, :vault_in_use}
    end
  end

  def release_runtime_lock(handle) do
    Sqlite3.execute(handle, "ROLLBACK")
    Sqlite3.close(handle)
    :ok
  rescue
    _ -> {:error, :runtime_lock_failed}
  end

  @doc false
  def supported_version?(version) when is_binary(version),
    do: version == @supported_version or String.starts_with?(version, @supported_version <> " ")

  def supported_version?(_), do: false

  def available? do
    case Sqlite3.open(":memory:") do
      {:ok, handle} ->
        try do
          cipher_available?(handle)
        after
          Sqlite3.close(handle)
        end

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc false
  def cipher_available?(handle) do
    case rows(handle, "PRAGMA cipher_version") do
      {:ok, [[version]]} -> supported_version?(version)
      _ -> false
    end
  end

  @doc false
  def rows(handle, sql, bindings \\ []) do
    case Sqlite3.prepare(handle, sql) do
      {:ok, statement} ->
        try do
          with :ok <- Sqlite3.bind(statement, bindings),
               {:ok, rows} <- Sqlite3.fetch_all(handle, statement) do
            {:ok, rows}
          else
            _ -> {:error, :database_unavailable}
          end
        after
          Sqlite3.release(handle, statement)
        end

      _ ->
        {:error, :database_unavailable}
    end
  rescue
    _ -> {:error, :database_unavailable}
  end

  @doc false
  # Trusted configured roots only; reject symlink components, not merely the leaf.
  # sobelow_skip ["Traversal.FileModule"]
  def private_directory(directory) do
    directory = Path.expand(directory)

    directory
    |> Path.split()
    |> Enum.reduce_while(nil, &private_directory_part/2)
    |> case do
      ^directory -> File.chmod(directory, 0o700)
      _ -> {:error, :unsafe_directory}
    end
  end

  defp private_directory_part(part, parent) do
    path = if parent, do: Path.join(parent, part), else: part

    case File.lstat(path) do
      {:ok, %{type: :directory}} -> {:cont, path}
      {:error, :enoent} -> create_private_directory(path)
      _ -> {:halt, :error}
    end
  end

  # Only missing components of the trusted configured root reach this helper,
  # after lstat rejects symlink/non-directory components.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_private_directory(path) do
    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o700) do
      {:cont, path}
    else
      _ -> {:halt, :error}
    end
  end

  @doc false
  # sobelow_skip ["Traversal.FileModule"]
  def create_private_file(path) do
    result =
      case File.open(path, [:write, :binary, :exclusive]) do
        {:ok, file} -> File.close(file)
        {:error, :eexist} -> :ok
        _ -> {:error, :unsafe_file}
      end

    with :ok <- result,
         {:ok, %{type: :regular, links: 1}} <- File.lstat(path),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      _ -> {:error, :unsafe_file}
    end
  end
end
