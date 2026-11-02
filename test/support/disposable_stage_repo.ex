defmodule Lovelace.TestSupport.DisposableStageRepo do
  @moduledoc """
  Independently owned, non-sandbox SQLite pools sharing a disposable database.
  Every process must explicitly select its dynamic Repo; this is not inherited.
  """

  alias Lovelace.Repo

  def start!(directory) do
    File.mkdir_p!(directory)
    database = Path.join(directory, "coordination.db")
    {first, first_connection} = start_pool!(database)

    Code.require_file(
      Path.expand("../../priv/repo/migrations/20261102020618_create_stage_designer.exs", __DIR__)
    )

    Ecto.Migrator.run(
      Repo,
      [{20_261_102_020_618, Lovelace.Repo.Migrations.CreateStageDesigner}],
      :up,
      all: true,
      dynamic_repo: first,
      log: false
    )

    {second, second_connection} = start_pool!(database)

    %{
      first: first,
      second: second,
      first_connection: first_connection,
      second_connection: second_connection
    }
  end

  defp start_pool!(database) do
    tag = make_ref()

    {:ok, pid} =
      Repo.start_link(
        name: nil,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        busy_timeout: 25,
        timeout: 2_000,
        log: false,
        connection_listeners: {[self()], tag}
      )

    # Tests own lifecycle explicitly, including failure cleanup in on_exit.
    Process.unlink(pid)

    receive do
      {:connected, connection, ^tag} -> {pid, connection}
    after
      2_000 -> raise "Disposable SQLite connection did not start"
    end
  end

  def stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  end

  def on_repo(repo, fun) do
    previous = Repo.put_dynamic_repo(repo)
    barrier = Process.put(:lovelace_synthetic_sql_barriers, true)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
      Process.put(:lovelace_synthetic_sql_barriers, barrier)
    end
  end
end
