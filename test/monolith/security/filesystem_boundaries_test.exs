defmodule Monolith.Security.FilesystemBoundariesTest do
  use ExUnit.Case, async: false

  alias Monolith.Security.{Database, Keychain, Secret, Vault}

  setup do
    root = Path.expand("tmp/private-storage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.fetch_env!(:monolith, Monolith.Repo)

    Application.put_env(
      :monolith,
      Monolith.Repo,
      Keyword.put(previous, :database, Path.join(root, "owner.db"))
    )

    on_exit(fn ->
      Application.put_env(:monolith, Monolith.Repo, previous)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "private directory creation rejects symlink ancestors and ordinary files without touching targets",
       %{root: root} do
    target = Path.join(root, "target")
    File.mkdir!(target)
    File.chmod!(target, 0o755)
    link = Path.join(root, "linked")
    File.ln_s!(target, link)
    assert {:error, :unsafe_directory} = Database.private_directory(Path.join(link, "nested"))
    refute File.exists?(Path.join(target, "nested"))
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o755

    file = Path.join(root, "not-a-directory")
    File.write!(file, "retained original")
    assert {:error, :unsafe_directory} = Database.private_directory(Path.join(file, "nested"))
    assert File.read!(file) == "retained original"
  end

  test "private marker files reject symbolic and hard links without changing originals", %{
    root: root
  } do
    original = Path.join(root, "original")
    File.write!(original, "retained original")
    File.chmod!(original, 0o640)
    symbolic = Path.join(root, "symbolic")
    hard = Path.join(root, "hard")
    File.ln_s!(original, symbolic)
    File.ln!(original, hard)

    assert {:error, :unsafe_file} = Database.create_private_file(symbolic)
    assert {:error, :unsafe_file} = Database.create_private_file(hard)
    assert File.read!(original) == "retained original"
    assert Bitwise.band(File.stat!(original).mode, 0o777) == 0o640
    assert File.stat!(original).links == 2
    assert File.read_link!(symbolic) == original

    assert {:error, :unsafe_file} =
             Database.create_private_file(Path.join(root, "missing/marker"))
  end

  test "setup markers survive retries and unsafe markers fence setup", %{root: root} do
    assert :ok = Keychain.begin_setup()
    marker = Path.join(Keychain.directory(), ".setup-pending")
    File.write!(marker, "interrupted setup; preserve this journal")
    assert :ok = Keychain.begin_setup()
    assert Keychain.setup_pending?()
    assert File.read!(marker) == "interrupted setup; preserve this journal"
    assert Bitwise.band(File.stat!(marker).mode, 0o777) == 0o600
    assert :ok = Keychain.finish_setup()
    refute Keychain.setup_pending?()

    target = Path.join(root, "retained")
    File.write!(target, "never replace")
    File.ln_s!(target, marker)
    assert Keychain.setup_pending?()
    assert {:error, :unsafe_file} = Keychain.begin_setup()
    assert File.read!(target) == "never replace"
    assert File.read_link!(marker) == target
  end

  test "incomplete storage pairs never masquerade as an empty or configured installation", %{
    root: root
  } do
    database = Path.join(root, "owner.db")
    assert Vault.configuration_status() == :new
    File.write!(database, "synthetic retained database")
    assert Vault.configuration_status() == :migration_required
    File.rm!(database)
    File.mkdir_p!(Keychain.directory())
    File.write!(Keychain.path(), "synthetic retained keychain")
    assert Vault.configuration_status() == :unavailable
    File.write!(database, "synthetic retained database")
    assert Vault.configuration_status() == :configured
    assert File.read!(database) == "synthetic retained database"
    assert File.read!(Keychain.path()) == "synthetic retained keychain"
  end

  test "diagnostic inspection never exposes a password-bearing secret, including inside a message" do
    password = "synthetic private password sentinel"
    secret = %Secret{value: password}
    refute inspect(secret) =~ password
    refute inspect({:unlock, secret, %{password: secret}}) =~ password
  end
end
