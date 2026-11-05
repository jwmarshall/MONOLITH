# Loaded before Mix boot so each real maintenance task must load runtime config itself.
# Only a synthetic DATABASE_PATH is used; terminal input stops before authentication/export.
# Real production native calls remain enabled: unsupported hosts must fail closed.
Code.require_file("subprocess_coverage.ex", __DIR__)

defmodule Lovelace.SyntheticMaintenanceIO do
  def start(lines, observer), do: spawn_link(fn -> loop(lines, observer) end)

  defp loop(lines, observer) do
    receive do
      {:io_request, caller, ref, request} ->
        if match?({:get_line, _, _}, request), do: send(observer, :terminal_read)
        {reply, lines} = reply(request, lines)
        send(caller, {:io_reply, ref, reply})
        loop(lines, observer)

      :stop ->
        :ok
    end
  end

  defp reply({:get_geometry, :columns}, lines), do: {80, lines}
  defp reply({:setopts, _}, lines), do: {:ok, lines}
  defp reply({:get_line, _, _}, [line | rest]), do: {line, rest}
  defp reply({:get_line, _, _}, []), do: {:eof, []}
  defp reply({:put_chars, _, _}, lines), do: {:ok, lines}
  defp reply({:put_chars, _, _, _, _}, lines), do: {:ok, lines}
  defp reply(_, lines), do: {{:error, :enotsup}, lines}
end

defmodule Mix.Tasks.Lovelace.SyntheticMaintenance do
  use Mix.Task
  alias Lovelace.TestSupport.SubprocessCoverage

  def run([mode, root]) do
    unless Mix.env() == :prod, do: raise("Production configuration required")
    SubprocessCoverage.start()
    source = Path.join(root, "original.db")
    original = "synthetic retained original; never authenticate or export"
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    File.write!(source, original)
    unless System.fetch_env!("DATABASE_PATH") == source, do: raise("Unexpected fixture path")

    failure = attempt(mode)
    assert_terminal_reads(mode)
    assert_storage(mode, source, original, failure)
    assert_stopped()

    IO.puts(
      "Production maintenance #{mode}: configured path, retained original, no protected runtime"
    )
  end

  defp attempt(mode) do
    {task, lines} =
      case mode do
        "owner" -> {"lovelace.owner.setup", []}
        "migration" -> {"lovelace.vault.migrate", ["STOPPED\n"]}
        "google" -> {"lovelace.google.configure", ["synthetic unused owner password\n"]}
      end

    leader = Process.group_leader()
    terminal = Lovelace.SyntheticMaintenanceIO.start(lines, self())
    Process.group_leader(self(), terminal)
    previous_trap = Process.flag(:trap_exit, mode == "google")

    try do
      failure =
        try do
          Mix.Task.run(task)
          raise("Maintenance unexpectedly completed")
        rescue
          error in Mix.Error -> error
        end

      assert_failure(mode, failure)
      assert_native_shutdown(mode)
      assert_no_unexpected_exit()
      failure
    after
      Process.group_leader(self(), leader)
      send(terminal, :stop)
      Process.flag(:trap_exit, previous_trap)
    end
  end

  defp assert_failure(mode, failure) do
    expected =
      case {mode, native_available?()} do
        {"owner", _} ->
          "Existing local storage will not be replaced. Use the explicit vault migration procedure."

        {"migration", true} ->
          "Terminal input cancelled; rerun migration to resume"

        {"migration", false} ->
          "Migration stopped; native vault lock could not be confirmed"

        {"google", true} ->
          "Unable to unlock the local owner vault."

        {"google", false} ->
          "Local vault unavailable. Stop the server before configuring Google credentials."
      end

    unless Exception.message(failure) == expected,
      do: raise("Unexpected #{mode} maintenance failure: #{Exception.message(failure)}")
  end

  defp assert_native_shutdown("google") do
    unless native_available?() do
      # A failed start_link also signals its caller. Observe the exact native
      # refusal rather than letting it kill the fixture or accepting any exit.
      receive do
        {:EXIT, supervisor,
         {:shutdown, {:failed_to_start_child, Lovelace.Security.Vault, :vault_unavailable}}}
        when is_pid(supervisor) ->
          :ok
      after
        5_000 -> raise("Missing fail-closed native vault shutdown")
      end
    end
  end

  defp assert_native_shutdown(_), do: :ok

  defp assert_no_unexpected_exit do
    receive do
      {:EXIT, _process, reason} when reason != :normal ->
        raise("Unexpected linked maintenance failure: #{inspect(reason)}")
    after
      0 -> :ok
    end
  end

  defp native_available? do
    :os.type() == {:unix, :darwin} and
      File.regular?(Application.app_dir(:lovelace, "priv/native/lovelace-vault"))
  end

  defp assert_terminal_reads(mode) do
    expected = %{"owner" => 0, "migration" => 2, "google" => 1}

    unless terminal_reads() == Map.fetch!(expected, mode),
      do: raise("Maintenance crossed its intended terminal-input boundary")
  end

  defp terminal_reads(count \\ 0) do
    receive do
      :terminal_read -> terminal_reads(count + 1)
    after
      0 -> count
    end
  end

  defp assert_storage(mode, source, original, failure) do
    unless Application.fetch_env!(:lovelace, Lovelace.Repo)[:database] == source,
      do:
        raise("Maintenance did not load production DATABASE_PATH: #{Exception.message(failure)}")

    unless File.read!(source) == original, do: raise("Original storage changed")
    vault = source <> ".vault"

    expected =
      case mode do
        "owner" -> not File.exists?(vault)
        "migration" -> File.dir?(Path.join(vault, "migration"))
        "google" -> File.regular?(Path.join(vault, ".runtime-lock.sqlite3"))
      end

    unless expected, do: raise("Maintenance did not preserve its intended storage boundary")

    if File.exists?(Path.join(vault, "lovelace.keychain-db")),
      do: raise("Maintenance unexpectedly created native credentials")
  end

  defp assert_stopped do
    for name <- [
          Lovelace.Supervisor,
          Lovelace.Repo,
          Lovelace.Security.Vault,
          Lovelace.Security.LeaseGuard,
          Lovelace.Security.ProtectedSupervisor,
          Lovelace.Mail.OAuth,
          Lovelace.Mail.ViewData,
          LovelaceWeb.Endpoint,
          Oban.Registry
        ] do
      if Process.whereis(name), do: raise("Protected application process survived maintenance")
    end
  end
end
