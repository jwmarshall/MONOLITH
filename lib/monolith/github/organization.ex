defmodule Monolith.GitHub.Organization do
  @moduledoc "Immutable GitHub installation owner and bounded, expiring read-only snapshots."
  use Ash.Resource,
    domain: Monolith.GitHub,
    primary_read_warning?: false,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Monolith.Repo
    table "github_organizations"
  end

  actions do
    read :read do
      primary? true
      prepare build(sort: [login: :asc, id: :asc])
    end

    read :due do
      filter expr(status == :ready and next_poll_at <= now())
      prepare build(sort: [next_poll_at: :asc], limit: 100)
    end

    create :connect do
      accept [
        :id,
        :github_id,
        :owner_type,
        :installation_id,
        :connection_id,
        :legacy_credential,
        :status,
        :login,
        :generation,
        :pull_requests,
        :repositories,
        :issues,
        :workflow_runs,
        :issue_count,
        :issues_truncated,
        :actions_truncated,
        :fetched_at,
        :truncated,
        :total_count,
        :partial_reasons,
        :next_poll_at,
        :last_error,
        :cooldown_until,
        :claim_id,
        :claimed_until
      ]
    end

    update :publish do
      require_atomic? false

      accept [
        :login,
        :owner_type,
        :installation_id,
        :connection_id,
        :legacy_credential,
        :generation,
        :status,
        :pull_requests,
        :repositories,
        :issues,
        :workflow_runs,
        :issue_count,
        :issues_truncated,
        :actions_truncated,
        :fetched_at,
        :last_error,
        :truncated,
        :total_count,
        :partial_reasons,
        :next_poll_at,
        :cooldown_until,
        :claimed_until,
        :claim_id
      ]
    end
  end

  policies do
    policy action_type(:read) do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
      authorize_if actor_attribute_equals(:role, :github_service)
    end

    policy action_type([:create, :update]) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :github_service)
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :github_id, :string, allow_nil?: false
    attribute :login, :string, allow_nil?: false, public?: true, constraints: [max_length: 39]

    attribute :owner_type, :atom,
      default: :organization,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:user, :organization]]

    attribute :installation_id, :integer, public?: true, constraints: [min: 1]
    attribute :legacy_credential, :boolean, default: false, allow_nil?: false, public?: true
    attribute :generation, :uuid, allow_nil?: false, public?: true

    attribute :status, :atom,
      default: :ready,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:ready, :disconnected, :reauthorization]]

    attribute :pull_requests, {:array, :map},
      default: [],
      allow_nil?: false,
      public?: true,
      sensitive?: true

    attribute :repositories, {:array, :map},
      default: [],
      allow_nil?: false,
      public?: true,
      sensitive?: true

    attribute :issues, {:array, :map},
      default: [],
      allow_nil?: false,
      public?: true,
      sensitive?: true

    attribute :workflow_runs, {:array, :map},
      default: [],
      allow_nil?: false,
      public?: true,
      sensitive?: true

    attribute :issue_count, :integer, public?: true
    attribute :issues_truncated, :boolean, default: false, allow_nil?: false, public?: true
    attribute :actions_truncated, :boolean, default: false, allow_nil?: false, public?: true

    attribute :fetched_at, :utc_datetime_usec, public?: true

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

    attribute :truncated, :boolean, default: false, allow_nil?: false, public?: true
    attribute :total_count, :integer, public?: true
    attribute :partial_reasons, {:array, :string}, default: [], allow_nil?: false, public?: true
    attribute :next_poll_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :cooldown_until, :utc_datetime_usec
    attribute :claimed_until, :utc_datetime_usec
    attribute :claim_id, :uuid
    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :connection, Monolith.GitHub.Connection, public?: true
  end

  identities do
    identity :github_identity, [:github_id]
  end
end
