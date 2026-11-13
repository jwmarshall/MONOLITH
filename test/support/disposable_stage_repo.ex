defmodule Monolith.TestSupport.DisposableStageRepo do
  @moduledoc """
  Independently owned, non-sandbox SQLite pools sharing a disposable database.
  Every process must explicitly select its dynamic Repo; this is not inherited.
  """

  alias Monolith.Repo

  def start!(directory, opts \\ []) do
    File.mkdir_p!(directory)
    database = Path.join(directory, "coordination.db")
    {first, first_connection} = start_pool!(database)

    migrations = [
      {20_261_102_020_618, "20261102020618_create_stage_designer.exs",
       Monolith.Repo.Migrations.CreateStageDesigner},
      {20_261_103_014_313, "20261103014313_add_scene_selection.exs",
       Monolith.Repo.Migrations.AddSceneSelection},
      {20_261_103_040_753, "20261103040753_add_scene_catalog.exs",
       Monolith.Repo.Migrations.AddSceneCatalog},
      tracking_migration()
    ]

    count = %{initial: 1, selection: 2, catalog: 4}[Keyword.get(opts, :through, :catalog)]
    migrations = Enum.take(migrations, count)

    migrate!(first, migrations)

    {second, second_connection} = start_pool!(database)

    %{
      first: first,
      second: second,
      first_connection: first_connection,
      second_connection: second_connection
    }
  end

  def tracking_migration do
    {20_261_103_210_745, "20261103210745_tracked_gemini_generations.exs",
     Monolith.Repo.Migrations.TrackedGeminiGenerations}
  end

  def migrate!(repo, migrations) do
    versions =
      Enum.map(migrations, fn {version, file, module} ->
        unless Code.ensure_loaded?(module),
          do: Code.require_file(Path.expand("../../priv/repo/migrations/" <> file, __DIR__))

        {version, module}
      end)

    Ecto.Migrator.run(Repo, versions, :up, all: true, dynamic_repo: repo, log: false)
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
    barrier = Process.put(:monolith_synthetic_sql_barriers, true)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
      Process.put(:monolith_synthetic_sql_barriers, barrier)
    end
  end
end
