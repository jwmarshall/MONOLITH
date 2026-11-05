defmodule Lovelace.Repo.Migrations.AddGithubRepositoryReadouts do
  use Ecto.Migration

  def up do
    alter table(:github_organizations) do
      add :repositories, {:array, :map}, null: false, default: []
      add :issues, {:array, :map}, null: false, default: []
      add :workflow_runs, {:array, :map}, null: false, default: []
      add :issue_count, :bigint
      add :issues_truncated, :boolean, null: false, default: false
      add :actions_truncated, :boolean, null: false, default: false
    end

    alter table(:workspace_github_organizations) do
      add :repository_ids, {:array, :text}, null: false, default: []
    end

    # Existing PR rows have no immutable repository ID. Expire only the bounded
    # provider cache; retain every connection, owner and workspace membership.
    execute("""
    UPDATE github_organizations
       SET pull_requests = '[]', total_count = NULL, fetched_at = NULL,
           truncated = 0, partial_reasons = '[]', claim_id = NULL, claimed_until = NULL
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "GitHub repository selections and readouts cannot be downgraded without losing selections"
  end
end
