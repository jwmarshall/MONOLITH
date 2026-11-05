defmodule Lovelace.Repo.Migrations.AddOnboardingWorkspace do
  use Ecto.Migration

  def up do
    alter table(:onboarding_states) do
      add :workspace_id,
          references(:workspaces,
            column: :id,
            name: "onboarding_states_workspace_id_fkey",
            type: :uuid
          )
    end

    # Older guides always used this workspace. Preserve that exact association,
    # including renamed starters; never choose another workspace by its name.
    execute """
    UPDATE onboarding_states
    SET workspace_id = '00000000-0000-4000-8000-000000000001'
    WHERE workspace_id IS NULL
      AND EXISTS (
        SELECT 1 FROM workspaces
        WHERE id = '00000000-0000-4000-8000-000000000001'
      )
    """
  end

  def down do
    alter table(:onboarding_states) do
      remove :workspace_id
    end
  end
end
