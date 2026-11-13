defmodule Monolith.Repo.Migrations.AddStartupScenePreference do
  @moduledoc "Adds the owner-saved automatic scenery opt-in without changing generation state."
  use Ecto.Migration

  def up do
    create table(:stage_designer_startup_preferences, primary_key: false) do
      add :enabled, :boolean, null: false
      add :id, :bigint, null: false, primary_key: true
    end
  end

  def down do
    drop table(:stage_designer_startup_preferences)
  end
end
