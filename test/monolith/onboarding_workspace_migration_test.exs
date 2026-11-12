defmodule Monolith.OnboardingWorkspaceMigrationTest do
  use ExUnit.Case, async: false

  alias Monolith.{Onboarding, Repo, Workspaces}
  alias Monolith.TestSupport.DisposableStageRepo, as: Disposable

  @moduletag :tmp_dir
  @owner [actor: %{role: :local_owner}]
  @legacy_id "00000000-0000-4000-8000-000000000001"
  @migration {20_261_104_143_000, "20261104143000_add_onboarding_workspace.exs",
              Monolith.Repo.Migrations.AddOnboardingWorkspace}

  setup %{tmp_dir: directory} do
    pools = Disposable.start!(directory, through: :initial)

    on_exit(fn ->
      Disposable.stop(pools.second)
      Disposable.stop(pools.first)
    end)

    Disposable.migrate!(pools.first, [
      {20_261_102_052_838, "20261102052838_create_workspaces.exs",
       Monolith.Repo.Migrations.CreateWorkspaces},
      {20_261_104_133_000, "20261104133000_add_onboarding_progress.exs",
       Monolith.Repo.Migrations.AddOnboardingProgress}
    ])

    %{repo: pools.first}
  end

  test "backfill preserves the exact renamed starter and all saved guide fields", %{repo: repo} do
    Disposable.on_repo(repo, fn ->
      Repo.query!(
        "INSERT INTO workspaces (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
        [
          @legacy_id,
          "Renamed reading room",
          "2026-11-01T10:00:00.000000Z",
          "2026-11-02T11:00:00.000000Z"
        ]
      )

      Repo.query!(
        "INSERT INTO onboarding_states (id, step, credentials_saved, finished) VALUES (1, 'complete', 1, 1)"
      )
    end)

    Disposable.migrate!(repo, [@migration])

    Disposable.on_repo(repo, fn ->
      assert {:ok,
              %{
                workspace_id: @legacy_id,
                step: :complete,
                credentials_saved: true,
                finished: true
              }} = Onboarding.progress(@owner)

      assert {:ok, %{id: @legacy_id, name: "Renamed reading room"}} = Onboarding.workspace(@owner)
      assert [%{id: @legacy_id}] = Workspaces.list_workspaces!(@owner)
      assert {:ok, %{workspace_id: @legacy_id, finished: true}} = Onboarding.start(@owner)
    end)
  end

  test "backfill never associates a different workspace merely named Personal", %{repo: repo} do
    other =
      Disposable.on_repo(repo, fn ->
        workspace = Workspaces.create_workspace!("Personal", @owner)

        Repo.query!(
          "INSERT INTO onboarding_states (id, step, credentials_saved, finished) VALUES (1, 'calendar', 1, 0)"
        )

        workspace
      end)

    Disposable.migrate!(repo, [@migration])

    Disposable.on_repo(repo, fn ->
      assert {:ok,
              %{workspace_id: nil, step: :calendar, credentials_saved: true, finished: false}} =
               Onboarding.progress(@owner)

      assert {:error, :workspace_required} = Onboarding.continue(:calendar, @owner)
      assert {:error, :workspace_required} = Onboarding.finish(@owner)
      assert [%{id: id, name: "Personal"}] = Workspaces.list_workspaces!(@owner)
      assert id == other.id
      assert {:ok, nil} = Onboarding.workspace(@owner)
    end)
  end
end
