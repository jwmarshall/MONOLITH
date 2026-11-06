defmodule Lovelace.GitHub.Connection do
  @moduledoc "GitHub user identity and durable refresh-rotation fence; secrets stay in the keychain."
  use Ash.Resource,
    domain: Lovelace.GitHub,
    primary_read_warning?: false,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "github_connections"
  end

  actions do
    read :read do
      primary? true
      prepare build(sort: [login: :asc, id: :asc])
    end

    create :authorize do
      accept [:id, :github_id, :login, :generation, :status, :last_error]
    end

    update :transition do
      require_atomic? false

      accept [
        :login,
        :generation,
        :status,
        :last_error,
        :discovery_id,
        :discovery_generation,
        :discovery_client_generation,
        :discovery_owner_fence,
        :discovery_status,
        :discovery_job_id,
        :discovery_error
      ]
    end
  end

  policies do
    policy action_type(:read) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
      authorize_if actor_attribute_equals(:role, :github_service)
    end

    policy action_type([:create, :update]) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :github_service)
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :github_id, :string, allow_nil?: false, public?: true
    attribute :login, :string, allow_nil?: false, public?: true, constraints: [max_length: 39]
    attribute :generation, :uuid, allow_nil?: false, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:ready, :refreshing, :reauthorization, :disconnected]]

    attribute :last_error, :atom,
      public?: true,
      constraints: [
        one_of: [
          :unavailable,
          :provider,
          :rate_limited,
          :reconnect,
          :keychain,
          :configuration,
          :denied,
          :expired
        ]
      ]

    attribute :discovery_id, :uuid, public?: true
    attribute :discovery_generation, :uuid
    attribute :discovery_client_generation, :uuid
    attribute :discovery_owner_fence, :map, allow_nil?: false, default: %{}
    attribute :discovery_job_id, :integer, public?: true

    attribute :discovery_status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :running, :succeeded, :failed, :superseded]]

    attribute :discovery_error, :atom,
      public?: true,
      constraints: [
        one_of: [
          :unavailable,
          :provider,
          :rate_limited,
          :reconnect,
          :keychain,
          :configuration,
          :denied,
          :expired
        ]
      ]

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    identity :github_user, [:github_id]
  end
end
