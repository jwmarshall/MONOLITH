defmodule Lovelace.StageDesigner.SceneCatalogMigrationTest do
  use ExUnit.Case, async: false

  alias Lovelace.Repo
  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.Scene
  alias Lovelace.TestSupport.DisposableStageRepo

  @service %{role: :stage_designer}
  @now ~U[2026-11-01 12:00:00.123456Z]
  @older ~U[2026-10-30 08:00:00.654321Z]
  @selection {20_261_103_014_313, "20261103014313_add_scene_selection.exs",
              Lovelace.Repo.Migrations.AddSceneSelection}
  @catalog {20_261_103_040_753, "20261103040753_add_scene_catalog.exs",
            Lovelace.Repo.Migrations.AddSceneCatalog}

  for through <- [:initial, :selection] do
    test "catalog upgrade from #{through} preserves all known history and timestamps" do
      repos = disposable!(unquote(through))
      latest = String.duplicate("a", 64)
      older = String.duplicate("b", 64)
      unknown = String.duplicate("c", 64)

      DisposableStageRepo.on_repo(repos.first, fn ->
        Repo.query!(
          """
          INSERT INTO stage_designer_states (id, version, status, generated_at, history)
          VALUES (1, 4, 'ready', ?, ?)
          """,
          ["2026-11-01 12:00:00.123456", Jason.encode!([latest, older, unknown])]
        )

        if unquote(through) == :selection do
          Repo.query!(
            "UPDATE stage_designer_states SET scene_dates = ?, selected_digest = ? WHERE id = 1",
            [Jason.encode!(%{older => DateTime.to_iso8601(@older)}), older]
          )
        end
      end)

      DisposableStageRepo.migrate!(repos.first, [
        @selection,
        @catalog,
        DisposableStageRepo.tracking_migration()
      ])

      DisposableStageRepo.on_repo(repos.second, fn ->
        {:ok, scenes, false} = Scene.page(1)
        assert length(scenes) == 3
        dates = Map.new(scenes, &{&1.digest, &1.generated_at})
        assert dates[latest] == @now
        assert dates[older] == if(unquote(through) == :selection, do: @older, else: nil)
        assert dates[unknown] == nil
        state = StageDesigner.get_state!(1, actor: @service)
        assert state.history == [latest, older, unknown]
        assert state.version == 4
        assert state.generated_at == @now
        assert state.selected_digest == if(unquote(through) == :selection, do: older, else: nil)
      end)
    end
  end

  test "fresh installation has an empty usable catalog without inventing state" do
    repos = disposable!(:catalog)

    DisposableStageRepo.on_repo(repos.first, fn ->
      assert {:ok, [], false} = Scene.page(1)
      assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
      assert {:ok, _scene} = Scene.publish(String.duplicate("d", 64), nil)
      assert {:ok, [%{generated_at: nil}], false} = Scene.page(1)
    end)
  end

  defp disposable!(through) do
    directory = Path.join(System.tmp_dir!(), "lovelace-catalog-migration-#{Ash.UUID.generate()}")
    repos = DisposableStageRepo.start!(directory, through: through)

    on_exit(fn ->
      DisposableStageRepo.stop(repos.first)
      DisposableStageRepo.stop(repos.second)
      File.rm_rf!(directory)
    end)

    repos
  end
end
