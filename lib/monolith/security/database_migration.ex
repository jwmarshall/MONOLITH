defmodule Monolith.Security.DatabaseMigration do
  @moduledoc false
  # Infrastructure only: never starts the application, Repo, jobs, or providers.
  alias Exqlite.Sqlite3
  alias Monolith.Owner.Password
  alias Monolith.Security.{CipherKey, Database}

  def authenticate(path, password, key \\ nil) do
    with_handle(path, :readonly, fn handle ->
      with :ok <- key(handle, key),
           {:ok, [[hash]]} <-
             Database.rows(handle, "SELECT hashed_password FROM owner_credentials WHERE id = ?", [
               "owner"
             ]),
           true <- Password.valid?(password, hash) do
        :ok
      else
        _ -> {:error, :authentication_failed}
      end
    end)
  end

  # The source is explicitly attached read-only. Even the final connection
  # close cannot checkpoint/delete its original WAL before cutover consent.
  # Runtime exclusion and the operator's stopped-server confirmation provide
  # quiescence; the read transaction includes committed WAL as one snapshot.
  def export(source, destination, key, password) do
    with_handle(":memory:", :uri, fn handle ->
      source_uri =
        "file:" <>
          URI.encode(Path.expand(source), &(&1 == ?/ or URI.char_unreserved?(&1))) <> "?mode=ro"

      with true <- Database.cipher_available?(handle),
           :ok <- Sqlite3.set_busy_timeout(handle, 1_000),
           :ok <- Sqlite3.execute(handle, "PRAGMA temp_store = MEMORY"),
           {:ok, _} <-
             Database.rows(handle, "ATTACH DATABASE ? AS plaintext KEY ''", [source_uri]),
           :ok <- Sqlite3.execute(handle, "BEGIN"),
           {:ok, [[hash]]} <-
             Database.rows(
               handle,
               "SELECT hashed_password FROM plaintext.owner_credentials WHERE id = ?",
               ["owner"]
             ),
           true <- Password.valid?(password, hash),
           :ok <- create_new(destination),
           :ok <- attach(handle, destination, key),
           {:ok, [[user_version]]} <- Database.rows(handle, "PRAGMA plaintext.user_version"),
           {:ok, [[application_id]]} <- Database.rows(handle, "PRAGMA plaintext.application_id"),
           {:ok, [[auto_vacuum]]} <- Database.rows(handle, "PRAGMA plaintext.auto_vacuum"),
           :ok <- Sqlite3.execute(handle, "PRAGMA encrypted.auto_vacuum = #{auto_vacuum}"),
           {:ok, _} <- Database.rows(handle, "SELECT sqlcipher_export('encrypted', 'plaintext')"),
           :ok <- Sqlite3.execute(handle, "PRAGMA encrypted.user_version = #{user_version}"),
           :ok <- Sqlite3.execute(handle, "PRAGMA encrypted.application_id = #{application_id}"),
           :ok <- compare(handle),
           {:ok, accounts} <-
             Database.rows(handle, "SELECT id FROM plaintext.gmail_accounts ORDER BY id"),
           :ok <- Sqlite3.execute(handle, "COMMIT"),
           :ok <- Sqlite3.execute(handle, "DETACH DATABASE encrypted"),
           :ok <- verify(destination, key) do
        {:ok, List.flatten(accounts)}
      else
        _ -> {:error, :export_failed}
      end
    end)
  rescue
    _ -> {:error, :export_failed}
  end

  def verify(path, key) do
    with :ok <- with_handle(path, :readonly, &verify_handle(&1, key)),
         true <- rejects?(path, nil),
         true <- rejects?(path, Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)) do
      :ok
    else
      _ -> {:error, :verification_failed}
    end
  end

  defp verify_handle(handle, key) do
    with true <- Database.cipher_available?(handle),
         :ok <- key(handle, key),
         {:ok, [[count]]} when is_integer(count) <-
           Database.rows(handle, "SELECT count(*) FROM sqlite_schema"),
         {:ok, [["ok"]]} <- Database.rows(handle, "PRAGMA integrity_check"),
         {:ok, []} <- Database.rows(handle, "PRAGMA cipher_integrity_check"),
         {:ok, []} <- Database.rows(handle, "PRAGMA foreign_key_check"),
         {:ok, [[header_size]]} when header_size in [0, "0"] <-
           Database.rows(handle, "PRAGMA cipher_plaintext_header_size") do
      :ok
    else
      _ -> {:error, :verification_failed}
    end
  end

  defp rejects?(path, key) do
    with_handle(path, :readonly, fn handle ->
      :ok = key(handle, key)
      match?({:error, _}, Database.rows(handle, "SELECT count(*) FROM sqlite_schema"))
    end) == true
  end

  defp key(_handle, nil), do: :ok

  defp key(handle, value) do
    Sqlite3.execute(handle, "PRAGMA key = #{CipherKey.new!(value)}")
  end

  defp attach(handle, destination, value) do
    # Fixed trusted destination path is a bound parameter, never SQL text.
    case Database.rows(handle, "ATTACH DATABASE ? AS encrypted KEY #{CipherKey.new!(value)}", [
           destination
         ]) do
      {:ok, _} ->
        Sqlite3.execute(
          handle,
          "PRAGMA encrypted.cipher_plaintext_header_size = 0; PRAGMA cipher_memory_security = ON"
        )

      _ ->
        {:error, :export_failed}
    end
  end

  defp compare(handle) do
    schema =
      "SELECT type, name, tbl_name, sql FROM %s.sqlite_schema WHERE name NOT LIKE 'sqlite_autoindex_%' ORDER BY type, name"

    with {:ok, source} <- Database.rows(handle, String.replace(schema, "%s", "plaintext")),
         {:ok, ^source} <- Database.rows(handle, String.replace(schema, "%s", "encrypted")),
         {:ok, tables} <-
           Database.rows(
             handle,
             "SELECT name FROM plaintext.sqlite_schema WHERE type = 'table' ORDER BY name"
           ) do
      Enum.reduce_while(tables, :ok, fn [name], :ok -> compare_table(handle, name) end)
    else
      _ -> {:error, :schema_mismatch}
    end
  end

  defp compare_table(handle, name) do
    table = quote_identifier(name)
    # EXCEPT in both directions detects changed values; COUNT also protects
    # duplicate multiplicity, using GROUP BY over every column.
    with {:ok, columns} <- Database.rows(handle, "PRAGMA plaintext.table_info(#{table})"),
         groups <-
           Enum.map_join(columns, ", ", fn [_id, column | _] -> quote_identifier(column) end),
         true <- groups != "",
         {:ok, []} <- difference(handle, "plaintext", "encrypted", table, groups),
         {:ok, []} <- difference(handle, "encrypted", "plaintext", table, groups) do
      {:cont, :ok}
    else
      _ -> {:halt, {:error, :data_mismatch}}
    end
  end

  defp difference(handle, left, right, table, groups) do
    Database.rows(
      handle,
      "SELECT #{groups}, count(*) FROM #{left}.#{table} GROUP BY #{groups} " <>
        "EXCEPT SELECT #{groups}, count(*) FROM #{right}.#{table} GROUP BY #{groups} LIMIT 1"
    )
  end

  defp quote_identifier(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""

  # sobelow_skip ["Traversal.FileModule"]
  defp create_new(path) do
    with {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      File.close(file)
      File.chmod(path, 0o600)
    end
  end

  defp with_handle(path, mode, fun) do
    # Exqlite's high-level mode whitelist omits SQLITE_OPEN_URI. This one raw
    # open enables SQLite's documented mode=ro URI for the attached source;
    # without it an ordinary read/write main handle could mutate the source.
    opened =
      if mode == :uri do
        flags =
          Exqlite.Flags.put_file_open_flags([
            :sqlite_open_readwrite,
            :sqlite_open_create,
            :sqlite_open_uri
          ])

        Exqlite.Sqlite3NIF.open(path, flags)
      else
        Sqlite3.open(path, mode: mode)
      end

    case opened do
      {:ok, handle} ->
        try do
          fun.(handle)
        after
          Sqlite3.close(handle)
        end

      _ ->
        {:error, :database_unavailable}
    end
  rescue
    _ -> {:error, :database_unavailable}
  catch
    _, _ -> {:error, :database_unavailable}
  end
end
