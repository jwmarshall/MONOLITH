# Separate production VM; every path is synthetic and every scenario stops before
# native credential creation or export. Reuse the hidden-input terminal fixture.
Code.require_file("vault_maintenance.exs", __DIR__)

defmodule Mix.Tasks.Lovelace.SyntheticBoundaries do
  use Mix.Task
  import ExUnit.Assertions
  alias Lovelace.TestSupport.SubprocessCoverage

  def run([mode, root]) do
    SubprocessCoverage.start()
    source = Path.join(root, "original.db")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    assert System.fetch_env!("DATABASE_PATH") == source
    {task, input, expected} = prepare(mode, source)
    before = files(root)
    leader = Process.group_leader()
    terminal = Lovelace.SyntheticMaintenanceIO.start(input, self())
    Process.group_leader(self(), terminal)

    try do
      error = assert_raise Mix.Error, fn -> Mix.Task.run(task) end

      cleanup_unavailable? =
        mode in ["migration_auth", "journal_invalid", "journal_identity", "journal_symlink"] and
          error.message == "Migration stopped; native vault lock could not be confirmed"

      assert error.message =~ expected or cleanup_unavailable?
    after
      Process.group_leader(self(), leader)
      send(terminal, :stop)
    end

    # Failed authorization or confirmation must preserve every existing byte,
    # including a journal the operator must retain for an attended retry.
    after_files = files(root)
    assert Map.take(after_files, Map.keys(before)) == before
    runtime_lock = source <> ".vault/.runtime-lock.sqlite3"
    assert Enum.all?(Map.keys(Map.drop(after_files, Map.keys(before))), &(&1 == runtime_lock))
    refute File.exists?(source <> ".vault/.migration-pending")
    # Cleanup can replace a migration refusal on hosts without the macOS helper.
    # Still prove journal rejection precedes password input, and failed owner
    # authentication precedes journal/marker creation, rather than accepting any error.
    reads = terminal_reads()

    expected_reads =
      case mode do
        mode when mode in ["owner_mismatch", "owner_short", "migration_auth"] -> 2
        _ -> 1
      end

    assert reads == expected_reads
    refute File.exists?(source <> ".vault/lovelace.keychain-db")
    refute File.exists?(source <> ".vault/migration/encrypted.sqlite3")
    assert Process.whereis(Lovelace.Repo) == nil
    assert Process.whereis(Lovelace.Security.Vault) == nil
    IO.puts("Terminal boundary #{mode}: originals retained; no credentials or export created")
  end

  defp prepare("owner_mismatch", _source),
    do:
      {"lovelace.owner.setup", ["synthetic owner password\n", "different password\n"],
       ~r/Passwords did not match/}

  defp prepare("owner_short", _source),
    do: {"lovelace.owner.setup", ["short\n", "short\n"], ~r/12–1024 characters/}

  defp prepare("owner_cancel", _source),
    do: {"lovelace.owner.setup", [], ~r/Password input cancelled/}

  defp prepare("google_cancel", _source),
    do: {"lovelace.google.configure", [], ~r/Credential input cancelled/}

  defp prepare("migration_cancel", source) do
    File.write!(source, "synthetic retained original")
    {"lovelace.vault.migrate", ["NO\n"], ~r/Cancelled/}
  end

  defp prepare("migration_auth", source) do
    File.write!(source, "synthetic invalid database; never export")

    {"lovelace.vault.migrate", ["STOPPED\n", "synthetic password\n"],
     ~r/Owner authentication failed/}
  end

  defp prepare(mode, source)
       when mode in ["journal_invalid", "journal_identity", "journal_symlink"] do
    File.write!(source, "synthetic retained original")
    directory = source <> ".vault/migration"
    File.mkdir_p!(directory)
    journal = Path.join(directory, "state.json")

    case mode do
      "journal_invalid" ->
        File.write!(journal, "not JSON")

      "journal_identity" ->
        File.write!(
          journal,
          :json.encode(%{"version" => 1, "source" => source <> ".other", "phase" => "building"})
        )

      "journal_symlink" ->
        File.ln_s!(source, journal)
    end

    expected =
      if mode == "journal_symlink",
        do: ~r/Unsafe migration journal/,
        else: ~r/Invalid migration journal/

    {"lovelace.vault.migrate", ["STOPPED\n"], expected}
  end

  defp terminal_reads(count \\ 0) do
    receive do
      :terminal_read -> terminal_reads(count + 1)
    after
      0 -> count
    end
  end

  defp files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {path, File.read!(path)} end)
  end
end
