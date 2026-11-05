defmodule Lovelace.Repo.Migrations.AddOnboardingProgress do
  use Ecto.Migration

  def up do
    create table(:onboarding_states, primary_key: false) do
      add :id, :bigint, null: false, primary_key: true
      add :step, :text, null: false
      add :credentials_saved, :boolean, null: false
      add :finished, :boolean, null: false
    end
  end

  def down do
    drop table(:onboarding_states)
  end
end
