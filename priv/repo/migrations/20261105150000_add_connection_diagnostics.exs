defmodule Monolith.Repo.Migrations.AddConnectionDiagnostics do
  use Ecto.Migration

  def change do
    create table(:connection_diagnostic_states, primary_key: false) do
      add :provider, :text, primary_key: true, null: false
      add :id, :uuid, null: false
      add :status, :text, null: false
      add :app_slug, :text
      add :job_id, :bigint
      add :requested_at, :utc_datetime_usec, null: false
    end
  end
end
