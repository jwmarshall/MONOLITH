defmodule Lovelace.StageDesigner.BundledScenesTest do
  use ExUnit.Case, async: false

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{BundledScenes, Image}
  alias Lovelace.TestSupport.DisposableStageRepo, as: DisposableRepo

  @actor %{role: :stage_designer}
  @migration {20_261_103_150_658, "20261103150658_add_bundled_scene_default.exs",
              Lovelace.Repo.Migrations.AddBundledSceneDefault}

  setup do
    directory = Path.join(System.tmp_dir!(), "lovelace-bundled-scenes-#{Ash.UUID.generate()}")
    pools = DisposableRepo.start!(directory)
    DisposableRepo.migrate!(pools.first, [@migration])

    on_exit(fn ->
      DisposableRepo.stop(pools.first)
      DisposableRepo.stop(pools.second)
      File.rm_rf!(directory)
    end)

    pools
  end

  test "an empty installation reads a bundled fallback without creating state", pools do
    DisposableRepo.on_repo(pools.first, fn ->
      assert StageDesigner.get_default_scene!(1, actor: @actor) == nil
      assert BundledScenes.default_url() == "/images/scenes/#{hd(BundledScenes.digests())}.jpg"
      assert StageDesigner.get_default_scene!(1, actor: @actor) == nil
      assert StageDesigner.get_state!(1, actor: @actor) == nil
    end)
  end

  test "boot chooses once, preserving the choice across repeated boots and independent connections",
       pools do
    chosen =
      DisposableRepo.on_repo(pools.first, fn ->
        assert :ignore = BundledScenes.initialize()
        StageDesigner.get_default_scene!(1, actor: @actor)
      end)

    assert chosen.digest in BundledScenes.digests()

    DisposableRepo.on_repo(pools.second, fn ->
      for _ <- 1..5 do
        assert :ignore = BundledScenes.initialize()
        assert StageDesigner.get_default_scene!(1, actor: @actor) == chosen
        assert BundledScenes.default_url() == "/images/scenes/#{chosen.digest}.jpg"
      end

      assert StageDesigner.get_state!(1, actor: @actor) == nil
      assert Ash.count!(StageDesigner.Scene, actor: @actor) == 0
    end)
  end

  test "concurrent boot initializers agree on the winning persisted choice", pools do
    tasks =
      for repo <- [pools.first, pools.second] do
        Task.async(fn ->
          DisposableRepo.on_repo(repo, fn ->
            StageDesigner.initialize_default_scene!(%{}, actor: @actor)
          end)
        end)
      end

    [first, second] = Enum.map(tasks, &Task.await/1)
    assert first.digest == second.digest
  end

  test "default selection actions require the internal scenery actor", pools do
    DisposableRepo.on_repo(pools.first, fn ->
      for actor <- [nil, %{}, %{role: :local_owner}, %{role: :mail_service}] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 StageDesigner.initialize_default_scene(%{}, actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} = StageDesigner.get_default_scene(1, actor: actor)
      end

      assert StageDesigner.get_default_scene!(1, actor: @actor) == nil
    end)
  end

  test "all three bundled originals are pinned, valid JPEGs", _pools do
    assert length(BundledScenes.digests()) == 3

    for digest <- BundledScenes.digests() do
      bytes =
        File.read!(Application.app_dir(:lovelace, "priv/static/images/scenes/#{digest}.jpg"))

      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == digest
      assert Image.format(bytes) == :jpeg
      assert Image.validate(bytes) == :ok
    end
  end
end
