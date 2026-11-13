defmodule Monolith.StageDesigner.StartupPreferenceMigrationTest do
  use ExUnit.Case, async: false

  alias Monolith.StageDesigner
  alias Monolith.StageDesigner.{Generation, Settings, StartupPreference}
  alias Monolith.TestSupport.DisposableStageRepo, as: DisposableRepo

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}
  @now ~U[2026-11-11 12:00:00.000000Z]
  @migration {20_261_111_120_000, "20261111120000_add_startup_scene_preference.exs",
              Monolith.Repo.Migrations.AddStartupScenePreference}
  @moduletag capture_log: true

  setup do
    directory =
      Path.join(System.tmp_dir!(), "monolith-startup-preference-migration-#{Ash.UUID.generate()}")

    pools = DisposableRepo.start!(directory)
    previous = Application.get_env(:monolith, :stage_designer)

    Application.put_env(:monolith, :stage_designer, %Settings{
      enabled: true,
      storage_dir: directory
    })

    on_exit(fn ->
      Application.put_env(:monolith, :stage_designer, previous)
      DisposableRepo.stop(pools.first)
      DisposableRepo.stop(pools.second)
      File.rm_rf!(directory)
    end)

    pools
  end

  test "unknown storage fails closed, and the environment veto does not read it", pools do
    DisposableRepo.on_repo(pools.first, fn ->
      assert {:error, _} = StageDesigner.startup_preference(actor: @owner)
      assert {:ok, :unavailable} = StageDesigner.generate_on_startup(actor: @service)
      assert {:ok, :unavailable} = StageDesigner.retry_failed_startup(actor: @service)
      assert :unavailable = Generation.startup(Settings.get(), @now, true)
      assert StageDesigner.get_state!(1, actor: @service) == nil

      Application.put_env(:monolith, :stage_designer, %{Settings.get() | enabled: false})
      assert {:ok, :disabled} = StageDesigner.generate_on_startup(actor: @service)
      assert {:ok, :disabled} = StageDesigner.retry_failed_startup(actor: @service)
      assert StageDesigner.get_state!(1, actor: @service) == nil
    end)
  end

  test "migration defaults off without changing cooldown or reservation and saves survive pools",
       pools do
    state =
      DisposableRepo.on_repo(pools.first, fn ->
        StageDesigner.initialize_state!(%{}, actor: @service)
        |> StageDesigner.reserve_state!(%{last_attempt_at: @now}, actor: @service)
      end)

    DisposableRepo.migrate!(pools.first, [@migration])

    DisposableRepo.on_repo(pools.second, fn ->
      assert %{enabled: false, environment_enabled: true} =
               StageDesigner.startup_preference!(actor: @owner)

      assert StageDesigner.get_startup_preference!(1, actor: @service) == nil

      assert {:ok, %{enabled: true}} =
               StageDesigner.save_startup_preference(%{enabled: true}, actor: @owner)
    end)

    for {repo, enabled} <- [{pools.first, true}, {pools.second, false}, {pools.first, true}] do
      DisposableRepo.on_repo(repo, fn ->
        assert {:ok, %{enabled: ^enabled}} =
                 StageDesigner.save_startup_preference(%{enabled: enabled}, actor: @owner)

        assert [%StartupPreference{id: 1, enabled: ^enabled}] =
                 Ash.read!(StartupPreference, actor: @service)

        unchanged = StageDesigner.get_state!(1, actor: @service)

        assert Map.drop(unchanged, [:__metadata__, :__meta__]) ==
                 Map.drop(state, [:__metadata__, :__meta__])
      end)
    end

    DisposableRepo.on_repo(pools.second, fn ->
      assert %{enabled: true} = StageDesigner.startup_preference!(actor: @owner)
    end)
  end
end
