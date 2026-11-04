defmodule Lovelace.Security.DatabaseTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Lovelace.Owner.Password
  alias Lovelace.Security.{CipherKey, Database, DatabaseMigration, Keychain}
  alias Mix.Tasks.Lovelace.Vault.Migrate

  @key String.duplicate("ab", 32)
  @password "synthetic migration owner password"

  setup do
    directory = Path.expand("tmp/lovelace-cipher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    previous_repo = Application.fetch_env!(:lovelace, Lovelace.Repo)
    previous_managed = Application.get_env(:lovelace, :vault_managed)

    Application.put_env(
      :lovelace,
      Lovelace.Repo,
      Keyword.put(previous_repo, :database, Path.join(directory, "fixture.db"))
    )

    on_exit(fn ->
      Application.put_env(:lovelace, Lovelace.Repo, previous_repo)

      if is_nil(previous_managed),
        do: Application.delete_env(:lovelace, :vault_managed),
        else: Application.put_env(:lovelace, :vault_managed, previous_managed)

      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "supported SQLCipher is mandatory, including in tests" do
    {:ok, handle} = Sqlite3.open(":memory:")

    try do
      assert Database.cipher_available?(handle),
             "Rebuild Exqlite against SQLCipher 4.20.0 with bin/lovelace-sqlcipher"

      assert Database.supported_version?("4.20.0 community")
      refute Database.supported_version?("4.20.1")
      refute Database.supported_version?(nil)
    after
      Sqlite3.close(handle)
    end
  end

  test "key option is redacted and managed startup rejects an unkeyed or bare-key Repo" do
    options = Database.repo_options(@key)
    assert %CipherKey{} = options[:key]
    refute inspect(options) =~ @key
    Application.put_env(:lovelace, :vault_managed, true)

    assert_raise RuntimeError, ~r/requires vault unlock/, fn ->
      Lovelace.Repo.init(:supervisor, [])
    end

    assert_raise RuntimeError, ~r/requires vault unlock/, fn ->
      Lovelace.Repo.init(:supervisor, key: @key)
    end

    assert {:ok, _guarded} = Lovelace.Repo.init(:supervisor, options)
  end

  test "pending or malformed migration journals fence managed startup" do
    Application.put_env(:lovelace, :vault_managed, true)
    root = Keychain.directory()
    File.mkdir_p!(Path.join(root, "migration"))
    File.write!(Path.join([root, "migration", "state.json"]), ~s({"phase":"cutover"}))
    assert Database.migration_pending?()

    assert_raise RuntimeError, ~r/migration is incomplete/, fn ->
      Lovelace.Repo.init(:supervisor, Database.repo_options(@key))
    end

    File.write!(Path.join([root, "migration", "state.json"]), "invalid")
    assert Database.migration_pending?()
  end

  test "runtime exclusion remains held until explicit release and rejects symlink sidecars", %{
    directory: directory
  } do
    assert {:ok, first} = Database.acquire_runtime_lock()

    try do
      assert {:error, :vault_in_use} = Database.acquire_runtime_lock()
      lock = Path.join(Keychain.directory(), ".runtime-lock.sqlite3")
      assert Bitwise.band(File.stat!(lock).mode, 0o777) == 0o600
    after
      assert :ok = Database.release_runtime_lock(first)
    end

    assert {:ok, second} = Database.acquire_runtime_lock()
    assert :ok = Database.release_runtime_lock(second)

    lock = Path.join(Keychain.directory(), ".runtime-lock.sqlite3")
    File.rm!(lock)
    target = Path.join(directory, "symlink-target")
    File.write!(target, "untouched")
    File.ln_s!(target, lock)
    assert {:error, :vault_in_use} = Database.acquire_runtime_lock()
    assert File.read!(target) == "untouched"
  end

  test "export includes committed WAL, preserves duplicates and rejects missing/wrong keys", %{
    directory: directory
  } do
    source = Path.join(directory, "plain.db")
    destination = Path.join(directory, "encrypted.db")
    {:ok, writer} = Sqlite3.open(source)

    try do
      assert Database.cipher_available?(writer)

      :ok =
        Sqlite3.execute(
          writer,
          "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0; CREATE TABLE owner_credentials(id TEXT PRIMARY KEY, hashed_password TEXT NOT NULL); CREATE TABLE gmail_accounts(id TEXT PRIMARY KEY); CREATE TABLE payloads(value TEXT, bytes BLOB); PRAGMA user_version = 17"
        )

      {:ok, hash} = Password.hash(@password)

      assert {:ok, []} =
               Database.rows(writer, "INSERT INTO owner_credentials VALUES (?, ?)", [
                 "owner",
                 hash
               ])

      assert {:ok, []} =
               Database.rows(writer, "INSERT INTO gmail_accounts VALUES (?)", [
                 "11111111-1111-4111-8111-111111111111"
               ])

      marker = "SYNTHETIC-PRIVATE-WAL-" <> String.duplicate("value", 500)

      assert {:ok, []} =
               Database.rows(writer, "INSERT INTO payloads VALUES (?, ?), (?, ?)", [
                 marker,
                 <<0, 1, 2>>,
                 marker,
                 <<0, 1, 2>>
               ])

      assert File.stat!(source <> "-wal").size > 0
      snapshot = Path.join(directory, "snapshot-with-committed-wal.db")
      File.cp!(source, snapshot)
      File.cp!(source <> "-wal", snapshot <> "-wal")
      original_main = File.read!(snapshot)
      original_wal = File.read!(snapshot <> "-wal")

      assert {:ok, ["11111111-1111-4111-8111-111111111111"]} =
               DatabaseMigration.export(snapshot, destination, @key, @password)

      assert File.read!(snapshot) == original_main
      assert File.read!(snapshot <> "-wal") == original_wal
      assert :ok = DatabaseMigration.verify(destination, @key)
      assert :ok = DatabaseMigration.authenticate(destination, @password, @key)
      assert {:error, _} = DatabaseMigration.authenticate(destination, "incorrect", @key)
      assert {:error, _} = DatabaseMigration.verify(destination, String.duplicate("cd", 32))
      refute File.read!(destination) =~ "SQLite format 3"
      refute File.read!(destination) =~ marker
      assert {:ok, [[2]]} = Database.rows(writer, "SELECT count(*) FROM payloads")
      {:ok, encrypted} = Sqlite3.open(destination)

      try do
        :ok =
          Sqlite3.execute(
            encrypted,
            "PRAGMA key = #{CipherKey.new!(@key)}; PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0"
          )

        assert {:ok, [[17]]} = Database.rows(encrypted, "PRAGMA user_version")

        assert {:ok, []} =
                 Database.rows(encrypted, "INSERT INTO payloads VALUES (?, ?)", [marker, <<4, 5>>])

        assert File.stat!(destination <> "-wal").size > 0
        refute File.read!(destination <> "-wal") =~ marker
      after
        Sqlite3.close(encrypted)
      end
    after
      Sqlite3.close(writer)
    end
  end

  test "incorrect owner password and conflicting destination never overwrite originals", %{
    directory: directory
  } do
    source = Path.join(directory, "plain.db")
    destination = Path.join(directory, "existing.db")
    {:ok, handle} = Sqlite3.open(source)

    :ok =
      Sqlite3.execute(
        handle,
        "CREATE TABLE owner_credentials(id TEXT PRIMARY KEY, hashed_password TEXT NOT NULL); CREATE TABLE gmail_accounts(id TEXT PRIMARY KEY)"
      )

    {:ok, hash} = Password.hash(@password)

    {:ok, []} =
      Database.rows(handle, "INSERT INTO owner_credentials VALUES (?, ?)", ["owner", hash])

    Sqlite3.close(handle)
    original = File.read!(source)
    assert {:error, _} = DatabaseMigration.export(source, destination, @key, "incorrect")
    refute File.exists?(destination)
    File.write!(destination, "do not overwrite")
    assert {:error, _} = DatabaseMigration.export(source, destination, @key, @password)
    assert File.read!(destination) == "do not overwrite"
    assert File.read!(source) == original
  end

  test "cutover resumes after a retained hardlink interruption without losing main or WAL", %{
    directory: directory
  } do
    source = Path.join(directory, "active.db")
    destination = Path.join(directory, "staged.db")
    backup = Path.join(directory, "backup")
    File.mkdir!(backup)
    File.write!(source, "original main")
    File.write!(source <> "-wal", "original committed WAL")
    File.write!(destination, "encrypted synthetic destination")

    fingerprint = fn path ->
      %{
        "sha256" => Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower),
        "size" => File.stat!(path).size
      }
    end

    inventory = %{"" => fingerprint.(source), "-wal" => fingerprint.(source <> "-wal")}
    File.ln!(source, Path.join(backup, "database.sqlite3"))
    assert :ok = Migrate.cutover!(source, destination, backup, inventory)
    assert File.read!(source) == "encrypted synthetic destination"
    assert File.read!(Path.join(backup, "database.sqlite3")) == "original main"
    assert File.read!(Path.join(backup, "database.sqlite3-wal")) == "original committed WAL"
    refute File.exists?(source <> "-wal")
    assert :ok = Migrate.cutover!(source, destination, backup, inventory)
  end

  test "cutover refuses an inventoried WAL changed after export and preserves partial progress",
       %{directory: directory} do
    fixture = cutover_fixture(directory)
    changed_wal = "changed committed WAL"
    File.write!(fixture.source <> "-wal", changed_wal)

    expected =
      fixture.files
      |> Map.delete("active.db")
      |> Map.put("backup/database.sqlite3", fixture.files["active.db"])
      |> Map.put("active.db-wal", changed_wal)

    assert_raise Mix.Error, ~r/Original changed since export/, fn ->
      Migrate.cutover!(
        fixture.source,
        fixture.destination,
        fixture.backup,
        fixture.inventory
      )
    end

    assert cutover_files(directory) == expected

    assert_raise Mix.Error, ~r/Original changed since export/, fn ->
      Migrate.cutover!(
        fixture.source,
        fixture.destination,
        fixture.backup,
        fixture.inventory
      )
    end

    assert cutover_files(directory) == expected
  end

  test "cutover refuses an unexpected sidecar after retaining every inventoried original", %{
    directory: directory
  } do
    fixture = cutover_fixture(directory)
    inventory = Map.delete(fixture.inventory, "-journal")

    expected =
      Enum.reduce(["", "-wal", "-shm"], fixture.files, fn suffix, files ->
        files
        |> Map.delete("active.db" <> suffix)
        |> Map.put("backup/database.sqlite3" <> suffix, fixture.files["active.db" <> suffix])
      end)

    assert_raise Mix.Error, ~r/Unexpected original sidecar/, fn ->
      Migrate.cutover!(
        fixture.source,
        fixture.destination,
        fixture.backup,
        inventory
      )
    end

    assert cutover_files(directory) == expected

    assert_raise Mix.Error, ~r/Unexpected original sidecar/, fn ->
      Migrate.cutover!(
        fixture.source,
        fixture.destination,
        fixture.backup,
        inventory
      )
    end

    assert cutover_files(directory) == expected
  end

  test "cutover refuses a conflicting retained original without replacing either copy", %{
    directory: directory
  } do
    fixture = cutover_fixture(directory)
    conflict = "independent retained WAL bytes"
    File.write!(Path.join(fixture.backup, "database.sqlite3-wal"), conflict)

    expected =
      fixture.files
      |> Map.delete("active.db")
      |> Map.put("backup/database.sqlite3", fixture.files["active.db"])
      |> Map.put("backup/database.sqlite3-wal", conflict)

    assert_raise Mix.Error, ~r/Original changed since export/, fn ->
      Migrate.cutover!(
        fixture.source,
        fixture.destination,
        fixture.backup,
        fixture.inventory
      )
    end

    assert cutover_files(directory) == expected

    assert_raise Mix.Error, ~r/Original changed since export/, fn ->
      Migrate.cutover!(
        fixture.source,
        fixture.destination,
        fixture.backup,
        fixture.inventory
      )
    end

    assert cutover_files(directory) == expected
  end

  defp cutover_fixture(directory) do
    source = Path.join(directory, "active.db")
    destination = Path.join(directory, "staged.db")
    backup = Path.join(directory, "backup")
    File.mkdir!(backup)

    originals = %{
      "" => "original main",
      "-wal" => "original committed WAL",
      "-shm" => "original shared memory",
      "-journal" => "original rollback journal"
    }

    inventory =
      Map.new(originals, fn {suffix, bytes} ->
        File.write!(source <> suffix, bytes)

        {suffix,
         %{
           "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
           "size" => byte_size(bytes)
         }}
      end)

    File.write!(destination, "encrypted synthetic destination")

    %{
      source: source,
      destination: destination,
      backup: backup,
      inventory: inventory,
      files: cutover_files(directory)
    }
  end

  defp cutover_files(directory) do
    directory
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.relative_to(path, directory), File.read!(path)} end)
  end
end
