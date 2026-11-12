defmodule Mix.Tasks.Monolith.Vault.Migrate do
  @shortdoc "Explicit terminal-only plaintext-to-vault migration (retains originals by default)"
  @moduledoc """
  Stop every MONOLITH server first, then run `mix monolith.vault.migrate` in a
  local terminal. No password arguments. The task authenticates the existing
  owner, exports to a separate SQLCipher database, verifies schema/data and
  correct/no/wrong-key behavior, and copies known credentials without deleting
  login-keychain items. Cutover and each deletion require separate exact phrases.

  Interruptions leave a private journal and fail-closed startup marker. Rerun
  this task to resume; never manually remove the marker or rename sidecars.
  Plaintext originals remain exposed in the announced backup until the operator
  explicitly confirms deletion. File deletion is not secure erasure on APFS/SSDs;
  snapshots, Time Machine, old backups, and exported environment files are outside
  this task. Forgotten vault password has no recovery path.
  """
  use Mix.Task

  alias Monolith.Integrations.Google.ClientCredentials
  alias Monolith.Security.{Database, DatabaseMigration, Keychain}

  @suffixes ["", "-wal", "-shm", "-journal"]
  @oauth_account "710dd510-61ed-4e6a-975c-78ce13f5d6e2"
  @oauth_service "MONOLITH Google OAuth"

  @impl true
  def run([]) do
    require_terminal!()
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = Application.ensure_all_started(:crypto)

    unless Database.available?(),
      do: Mix.raise("SQLCipher 4.20.0 is required; rebuild Exqlite with bin/monolith setup")

    unless Process.whereis(Monolith.Repo) == nil,
      do: Mix.raise("Migration requires a separate terminal with MONOLITH stopped")

    confirm!("Stop every MONOLITH server. Type STOPPED to continue: ", "STOPPED")
    {:ok, lock} = safe(Database.acquire_runtime_lock(), "Vault is in use; stop MONOLITH first")

    try do
      migrate!()
    after
      result = Keychain.lock()
      Database.release_runtime_lock(lock)

      unless result == :ok,
        do: Mix.raise("Migration stopped; native vault lock could not be confirmed")
    end
  rescue
    error in Mix.Error ->
      reraise error, __STACKTRACE__

    _ ->
      Mix.raise(
        "Vault migration stopped safely; retained files were not automatically removed. Rerun to resume."
      )
  catch
    _, _ -> Mix.raise("Vault migration interrupted; rerun to resume before starting MONOLITH")
  end

  def run(_),
    do: Mix.raise("Usage: mix monolith.vault.migrate (no passwords or paths in arguments)")

  defp migrate! do
    source =
      Application.fetch_env!(:monolith, Monolith.Repo)
      |> Keyword.fetch!(:database)
      |> Path.expand()

    root = Keychain.directory()
    directory = Path.join(root, "migration")
    pending = Path.join(root, ".migration-pending")
    journal = Path.join(directory, "state.json")
    destination = Path.join(directory, "encrypted.sqlite3")
    backup = Path.join(directory, "plaintext-originals")

    :ok = safe(Database.private_directory(directory), "Unsafe migration directory")
    state = load_state!(journal, source)
    password = hidden("Current owner password: ")

    state =
      if state["phase"] == "new" do
        if Keychain.configured?(),
          do:
            Mix.raise(
              "Vault already exists without a migration journal; refusing to overwrite it"
            )

        :ok = safe(regular!(source), "Plaintext source is unavailable")

        :ok =
          safe(DatabaseMigration.authenticate(source, password), "Owner authentication failed")

        state = %{"version" => 1, "source" => source, "phase" => "building"}
        write_state!(journal, state)
        write_new!(pending, "Migration incomplete; run mix monolith.vault.migrate\n")
        state
      else
        ensure_pending!(pending, state)
        state
      end

    :ok = safe(open_keychain(password), "Vault could not be opened; no existing key was replaced")

    {:ok, key} =
      safe(
        Keychain.database_key_for_migration(),
        "Existing vault database key could not be authorized; no key was replaced"
      )

    unless Keychain.database_key() == {:ok, key},
      do:
        Mix.raise(
          "Database-key approval did not persist for the current helper. Rerun migration and authorize only the verified MONOLITH helper; no key was replaced."
        )

    state =
      if state["phase"] == "building" do
        :ok =
          safe(DatabaseMigration.authenticate(source, password), "Owner authentication failed")

        abandon_partial!(destination)

        {:ok, accounts} =
          safe(
            DatabaseMigration.export(source, destination, key, password),
            "Encrypted export failed; original database retained"
          )

        credential_migration_result!(Keychain.copy_legacy(accounts))

        maybe_import_oauth!()
        sync!(destination)

        state =
          Map.merge(state, %{
            "phase" => "ready",
            "accounts" => accounts,
            "inventory" => inventory!(source)
          })

        write_state!(journal, state)
        state
      else
        state
      end

    verification_path = if state["phase"] == "complete", do: source, else: destination

    :ok =
      safe(
        DatabaseMigration.verify(verification_path, key),
        "Encrypted database failed verification"
      )

    :ok =
      safe(
        DatabaseMigration.authenticate(verification_path, password, key),
        "Owner authentication failed"
      )

    state =
      if state["phase"] in ["ready", "cutover"] do
        Mix.shell().info(
          "Encrypted export verified. Plaintext originals will remain in #{backup}."
        )

        confirm!(
          "Type CUT OVER to replace the active database (originals retained): ",
          "CUT OVER"
        )

        :ok = safe(Database.private_directory(backup), "Unsafe original-backup directory")
        state = Map.put(state, "phase", "cutover")
        write_state!(journal, state)
        cutover!(source, destination, backup, state["inventory"])
        state = Map.put(state, "phase", "complete")
        write_state!(journal, state)
        state
      else
        state
      end

    unless state["phase"] == "complete",
      do: Mix.raise("Unknown migration phase; refusing changes")

    :ok =
      safe(DatabaseMigration.verify(source, key), "Active encrypted database failed verification")

    if same_inode?(source, destination) do
      :ok = safe(remove_if_present(destination), "Could not detach completed staging file")
    end

    :ok = safe(remove_if_present(pending), "Migration marker could not be cleared")

    Mix.shell().info(
      "Vault migration complete. Startup remains locked. Plaintext backups and legacy credentials are retained unless separately deleted below."
    )

    maybe_delete_plaintext!(backup, state["inventory"])
    maybe_delete_legacy!(state["accounts"])
  end

  defp open_keychain(password) do
    if Keychain.configured?() and not Keychain.initializing?(),
      do: Keychain.unlock(password),
      else: Keychain.create(password)
  end

  # Journal phases are committed before filesystem mutations. A resumed cutover
  # accepts only exact retained originals or the staged inode at the active path.
  # It never overwrites a conflicting file and never removes original sidecars.
  # sobelow_skip ["Traversal.FileModule"]
  def cutover!(source, destination, backup, inventory) do
    Enum.each(@suffixes, fn suffix ->
      from = source <> suffix
      retained = Path.join(backup, "database.sqlite3" <> suffix)
      entry = Map.fetch(inventory, suffix)

      case original_cutover_action!(from, destination, retained, suffix, entry) do
        :retained ->
          :ok

        :detach ->
          :ok = safe(File.rm(from), "Could not detach retained original")

        :retain_and_detach ->
          # link is exclusive and preserves the original before unlinking its
          # old name; interruption between these operations is resumable.
          :ok = safe(File.ln(from, retained), "Could not retain original")
          sync!(retained)
          :ok = safe(File.rm(from), "Could not detach retained original")
      end
    end)

    unless same_inode?(source, destination) do
      :ok = safe(File.ln(destination, source), "Active path conflict; encrypted export retained")
    end

    sync!(source)
  end

  defp original_cutover_action!(from, destination, retained, suffix, {:ok, fingerprint}) do
    cond do
      same_inode?(from, destination) and suffix == "" ->
        assert_fingerprint!(retained, fingerprint)
        :retained

      File.exists?(retained) ->
        assert_fingerprint!(retained, fingerprint)
        retained_original_action!(from, retained)

      true ->
        assert_fingerprint!(from, fingerprint)
        :retain_and_detach
    end
  end

  defp original_cutover_action!(from, _destination, _retained, _suffix, :error) do
    if File.exists?(from),
      do: Mix.raise("Unexpected original sidecar; refusing cutover"),
      else: :retained
  end

  defp retained_original_action!(from, retained) do
    cond do
      same_inode?(from, retained) -> :detach
      File.exists?(from) -> Mix.raise("Conflicting source file; refusing cutover")
      true -> :retained
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp load_state!(journal, source) do
    case File.lstat(journal) do
      {:error, :enoent} ->
        %{"phase" => "new"}

      {:ok, %{type: :regular}} ->
        with {:ok, contents} <- File.read(journal),
             {:ok, %{"version" => 1, "source" => ^source, "phase" => phase} = state} <-
               Jason.decode(contents),
             true <- phase in ["building", "ready", "cutover", "complete"] do
          state
        else
          _ -> Mix.raise("Invalid migration journal; refusing to overwrite any file")
        end

      _ ->
        Mix.raise("Unsafe migration journal")
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_state!(journal, state) do
    temporary = journal <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    write_new!(temporary, Jason.encode!(state))
    :ok = safe(File.rename(temporary, journal), "Could not commit migration journal")
    sync!(journal)
  end

  defp ensure_pending!(_pending, %{"phase" => "complete"}), do: :ok

  defp ensure_pending!(pending, _state) do
    if File.exists?(pending) do
      :ok = safe(regular!(pending), "Unsafe migration marker")
    else
      write_new!(pending, "Migration incomplete; run mix monolith.vault.migrate\n")
    end
  end

  # Never overwrite partial encrypted files after an interrupted export.
  # sobelow_skip ["Traversal.FileModule"]
  defp abandon_partial!(destination) do
    Enum.each(@suffixes, fn suffix ->
      path = destination <> suffix

      case File.lstat(path) do
        {:error, :enoent} ->
          :ok

        {:ok, %{type: :regular}} ->
          :ok =
            safe(
              File.rename(
                path,
                path <>
                  ".interrupted-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
              ),
              "Could not retain interrupted export"
            )

        _ ->
          Mix.raise("Unsafe staged database")
      end
    end)
  end

  defp inventory!(source) do
    Map.new(
      Enum.flat_map(@suffixes, fn suffix ->
        path = source <> suffix

        case File.lstat(path) do
          {:error, :enoent} when suffix != "" -> []
          {:ok, %{type: :regular}} -> [{suffix, fingerprint!(path)}]
          _ -> Mix.raise("Original database or sidecar is missing/unsafe")
        end
      end)
    )
  end

  defp assert_fingerprint!(path, expected) do
    unless fingerprint!(path) == expected,
      do: Mix.raise("Original changed since export; refusing cutover")
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp fingerprint!(path) do
    :ok = safe(regular!(path), "Unsafe original file")

    digest =
      path
      |> File.stream!(65_536, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), fn bytes, context ->
        :crypto.hash_update(context, bytes)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    %{"sha256" => digest, "size" => File.stat!(path).size}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp same_inode?(left, right) do
    with {:ok, a} <- File.lstat(left), {:ok, b} <- File.lstat(right) do
      a.type == :regular and b.type == :regular and a.inode == b.inode and
        a.major_device == b.major_device
    else
      _ -> false
    end
  end

  defp maybe_import_oauth! do
    if confirm?(
         "Optionally import GOOGLE_CLIENT_ID/SECRET from this terminal environment? Type IMPORT OAUTH, or Enter to skip: ",
         "IMPORT OAUTH"
       ) do
      id = System.get_env("GOOGLE_CLIENT_ID")
      secret = System.get_env("GOOGLE_CLIENT_SECRET")

      :ok =
        safe(
          ClientCredentials.validate(id, secret),
          "OAuth environment configuration invalid; nothing imported"
        )

      encoded = Jason.encode!(%{client_id: id, client_secret: secret})
      unless byte_size(encoded) <= 16 * 1024, do: Mix.raise("OAuth configuration too large")

      case Keychain.get(@oauth_account, @oauth_service) do
        {:ok, ^encoded} ->
          :ok

        {:ok, _} ->
          Mix.raise("Existing OAuth credentials differ; refusing overwrite")

        {:error, :not_found} ->
          :ok = safe(Keychain.put(@oauth_account, encoded, @oauth_service), "OAuth import failed")

        _ ->
          Mix.raise("OAuth keychain unavailable; import refused")
      end
    end
  end

  defp maybe_delete_plaintext!(backup, inventory) do
    if confirm?(
         "Plaintext backups remain exposed. Type DELETE PLAINTEXT to delete retained originals, or Enter to retain: ",
         "DELETE PLAINTEXT"
       ) do
      Enum.each(inventory, fn {suffix, fingerprint} ->
        delete_plaintext!(Path.join(backup, "database.sqlite3" <> suffix), fingerprint)
      end)

      Mix.shell().info(
        "Retained plaintext files deleted; APFS snapshots/other backups are not erased."
      )
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp delete_plaintext!(path, fingerprint) do
    if File.exists?(path) do
      assert_fingerprint!(path, fingerprint)
      :ok = safe(File.rm(path), "Plaintext deletion incomplete; remaining originals retained")
    end
  end

  defp maybe_delete_legacy!(accounts) do
    if confirm?(
         "Type DELETE LEGACY SECRETS to delete verified migrated login-keychain items, or Enter to retain: ",
         "DELETE LEGACY SECRETS"
       ) do
      credential_migration_result!(Keychain.delete_legacy(accounts))
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp regular!(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      _ -> {:error, :unsafe_file}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_new!(path, contents) do
    {:ok, file} =
      safe(
        File.open(path, [:write, :binary, :exclusive]),
        "Migration file already exists/unavailable"
      )

    try do
      :ok = File.chmod(path, 0o600)
      :ok = IO.binwrite(file, contents)
      :ok = :file.sync(file)
    after
      File.close(file)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sync!(path) do
    {:ok, file} =
      safe(
        File.open(path, [:read, :write, :binary]),
        "Migration file unavailable for durable sync"
      )

    try do
      :ok = :file.sync(file)
    after
      File.close(file)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_if_present(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :file_unavailable}
    end
  end

  defp require_terminal! do
    unless match?({:ok, _}, :io.columns(:standard_io)),
      do: Mix.raise("A local interactive terminal is required")
  end

  defp hidden(label) do
    unless :io.setopts(:standard_io, echo: false) == :ok,
      do: Mix.raise("Hidden terminal input is required")

    try do
      value = input!(label)
      unless byte_size(value) <= 1024, do: Mix.raise("Password input exceeds limit")
      value
    after
      :io.setopts(:standard_io, echo: true)
      IO.puts("")
    end
  end

  defp confirm!(label, expected) do
    unless confirm?(label, expected),
      do: Mix.raise("Cancelled; no automatic cleanup or deletion performed")
  end

  defp confirm?(label, expected), do: input!(label) == expected

  defp input!(label) do
    case IO.gets(:stdio, label) do
      value when is_binary(value) ->
        value |> String.trim_trailing("\n") |> String.trim_trailing("\r")

      _ ->
        Mix.raise("Terminal input cancelled; rerun migration to resume")
    end
  end

  defp credential_migration_result!(:ok), do: :ok

  defp credential_migration_result!({:error, reason}) do
    detail =
      case reason do
        :conflict ->
          "A legacy credential differs from its vault copy; neither value was replaced."

        :legacy_locked ->
          "The macOS login keychain is locked. Unlock login in Keychain Access, then rerun migration."

        :legacy_authorization_required ->
          "Legacy credentials require macOS authorization. Build the current helper and rerun migration in a local terminal."

        :legacy_access_denied ->
          "Legacy credential authorization was cancelled or denied. Rerun migration and approve access only for the verified MONOLITH helper."

        :legacy_unavailable ->
          "The legacy login keychain could not be read. Check its availability in Keychain Access."

        :timeout ->
          "Credential authorization timed out. Rerun migration and respond to its macOS dialogs."

        :locked ->
          "Dedicated-vault item access is locked or denied. Approval must permit the current helper's later noninteractive access."

        _ ->
          "Credential migration is unavailable. Check the native helper build and macOS keychain access."
      end

    Mix.raise(
      "#{detail} Migration paused; remaining originals retained. Keep MONOLITH stopped and do not delete credentials, markers or backups."
    )
  end

  defp safe(:ok, _message), do: :ok
  defp safe({:ok, _} = result, _message), do: result
  defp safe(_result, message), do: Mix.raise(message)
end
