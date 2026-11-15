defmodule Monolith.Caching.Preference do
  @moduledoc "Three bounded, owner-saved integration cache preferences; no provider data."
  use Ash.Resource,
    domain: Monolith.Caching,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Monolith.Repo
    table "cache_preferences"
  end

  actions do
    defaults [:read]

    create :save_preferences do
      accept [:integration, :refresh_minutes, :retention_hours]
      upsert? true
      upsert_fields [:refresh_minutes, :retention_hours, :expired_before]
      change Monolith.Caching.PreserveExpiry

      validate compare(:refresh_minutes, greater_than_or_equal_to: 5),
        where: [attribute_equals(:integration, :github)]

      validate compare(:retention_hours, less_than_or_equal_to: 24),
        where: [attribute_equals(:integration, :calendar)]

      validate compare(:retention_hours, less_than_or_equal_to: 24),
        where: [attribute_equals(:integration, :github)]
    end
  end

  policies do
    policy action_type(:read) do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
      authorize_if Monolith.Caching.PolicyReader
    end

    policy action(:save_preferences) do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
    end
  end

  attributes do
    attribute :integration, :atom do
      constraints one_of: [:gmail, :calendar, :github]
      primary_key? true
      allow_nil? false
    end

    attribute :refresh_minutes, :integer do
      constraints min: 3, max: 60
      allow_nil? false
    end

    attribute :retention_hours, :integer do
      constraints min: 1, max: 168
      allow_nil? false
    end

    attribute :expired_before, :utc_datetime_usec do
      allow_nil? false
    end
  end
end
