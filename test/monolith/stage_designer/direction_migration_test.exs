defmodule Monolith.StageDesigner.DirectionMigrationTest do
  use ExUnit.Case, async: false

  alias Monolith.StageDesigner
  alias Monolith.StageDesigner.{Direction, DirectionOptions}
  alias Monolith.TestSupport.DisposableStageRepo, as: DisposableRepo

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}
  @migration {20_261_103_184_507, "20261103184507_add_scene_direction.exs",
              Monolith.Repo.Migrations.AddSceneDirection}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "monolith-direction-migration-#{Ash.UUID.generate()}")

    pools = DisposableRepo.start!(directory)

    on_exit(fn ->
      DisposableRepo.stop(pools.first)
      DisposableRepo.stop(pools.second)
      File.rm_rf!(directory)
    end)

    pools
  end

  test "migration adds empty direction storage without changing existing reservation", pools do
    state =
      DisposableRepo.on_repo(pools.first, fn ->
        StageDesigner.initialize_state!(%{}, actor: @service)
        |> StageDesigner.reserve_state!(%{last_attempt_at: ~U[2026-11-03 12:00:00Z]},
          actor: @service
        )
      end)

    DisposableRepo.migrate!(pools.first, [@migration])

    DisposableRepo.on_repo(pools.second, fn ->
      unchanged = StageDesigner.get_state!(1, actor: @service)

      assert Map.drop(unchanged, [:__metadata__, :__meta__]) ==
               Map.drop(state, [:__metadata__, :__meta__])

      assert StageDesigner.get_direction!(1, actor: @owner) == nil
      assert %{saved?: false} = StageDesigner.scene_direction!(actor: @owner)
      assert StageDesigner.get_direction!(1, actor: @owner) == nil
    end)
  end

  test "simultaneous first saves upsert one complete singleton and survive independent reads",
       pools do
    DisposableRepo.migrate!(pools.first, [@migration])
    first = DirectionOptions.defaults()
    second = %{subject: "abstract", setting: "coast", light: "dawn", palette: "mist"}
    parent = self()

    tasks =
      for {repo, values} <- [{pools.first, first}, {pools.second, second}] do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:save -> :ok)

          DisposableRepo.on_repo(repo, fn ->
            StageDesigner.save_scene_direction(values, actor: @owner)
          end)
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}, 1_000
        pid
      end

    Enum.each(pids, &send(&1, :save))

    for task <- tasks, do: assert({:ok, %{saved?: true}} = Task.await(task))

    for repo <- [pools.first, pools.second] do
      DisposableRepo.on_repo(repo, fn ->
        assert Ash.count!(Direction, actor: @service) == 1
        saved = StageDesigner.scene_direction!(actor: @owner)
        assert saved.values in [first, second]
        assert saved.prompt == DirectionOptions.compose(saved.values)
        assert StageDesigner.get_state!(1, actor: @service) == nil
      end)
    end
  end
end
