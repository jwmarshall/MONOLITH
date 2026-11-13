defmodule Monolith.StageDesigner.StartupPreference do
  @moduledoc "Owner-saved application-wide startup opt-in, absent until explicitly saved."
  use Ash.Resource,
    domain: Monolith.StageDesigner,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Monolith.Repo
    table "stage_designer_startup_preferences"
  end

  actions do
    defaults [:read]

    create :save do
      accept [:enabled]
      upsert? true
      upsert_fields [:enabled]
    end

    action :startup_preference, :map do
      run {Monolith.StageDesigner.StartupPreferences, operation: :read}
    end

    action :save_startup_preference, :map do
      argument :enabled, :boolean do
        allow_nil? false
      end

      run {Monolith.StageDesigner.StartupPreferences, operation: :save}
    end
  end

  policies do
    policy action_type(:read) do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
      authorize_if Monolith.StageDesigner.ServiceActor
    end

    policy action([:save, :startup_preference, :save_startup_preference]) do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
    end
  end

  attributes do
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      default 1
      constraints min: 1, max: 1
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default false
    end
  end
end
