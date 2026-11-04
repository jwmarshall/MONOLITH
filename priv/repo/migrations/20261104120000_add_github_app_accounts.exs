defmodule Lovelace.Repo.Migrations.AddGithubAppAccounts do
  use Ecto.Migration

  def up do
    create table(:github_connections, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :github_id, :text, null: false
      add :login, :text, null: false
      add :generation, :uuid, null: false
      add :status, :text, null: false
      add :last_error, :text
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:github_connections, [:github_id],
             name: "github_connections_github_user_index"
           )

    alter table(:github_organizations) do
      add :owner_type, :text, null: false, default: "organization"
      add :installation_id, :bigint
      add :legacy_credential, :boolean, null: false, default: false

      add :connection_id,
          references(:github_connections,
            column: :id,
            name: "github_organizations_connection_id_fkey",
            type: :uuid
          )
    end

    # PAT credentials are not App credentials. Keep owner identity, membership and
    # the original UUID keychain item; explicit owner disconnect can delete it.
    execute("""
    UPDATE github_organizations
       SET status = CASE WHEN status = 'disconnected' THEN 'disconnected' ELSE 'reauthorization' END,
           last_error = CASE WHEN status = 'disconnected' THEN last_error ELSE 'reconnect' END,
           legacy_credential = 1, pull_requests = '[]', fetched_at = NULL, total_count = NULL,
           truncated = 0, partial_reasons = '[]', claim_id = NULL,
           claimed_until = NULL, cooldown_until = NULL
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "GitHub App authorization cannot be downgraded to retained PAT credentials"
  end
end
