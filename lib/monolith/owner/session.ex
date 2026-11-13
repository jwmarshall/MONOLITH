defmodule Monolith.Owner.Session do
  @moduledoc "Revocable, absolute-expiry sessions. Only a SHA-256 token digest is persisted."
  use Ash.Resource,
    domain: Monolith.Owner,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Monolith.Repo
    table "owner_sessions"
  end

  actions do
    read :read do
      primary? true
    end

    create :issue do
      accept [:digest, :expires_at]
    end

    destroy :revoke

    action :verify, :map do
      argument :token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [trim?: false, max_length: 128]

      run {Monolith.Owner.Actions, operation: :verify}
    end

    action :verify_digest, :map do
      argument :digest, :string, allow_nil?: false, sensitive?: true
      run {Monolith.Owner.Actions, operation: :verify_digest}
    end

    action :logout, :boolean do
      argument :token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [trim?: false, max_length: 128]

      run {Monolith.Owner.Actions, operation: :logout}
    end

    action :lock_all, :boolean do
      run {Monolith.Owner.Actions, operation: :lock_all}
    end
  end

  policies do
    policy action([:read, :issue, :revoke, :verify_digest]) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :owner_auth_service)
    end

    policy action([:verify, :logout]) do
      authorize_if always()
    end

    policy action(:lock_all) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :local_owner)
    end
  end

  attributes do
    attribute :digest, :string do
      primary_key? true
      allow_nil? false
      sensitive? true
      constraints match: ~r/\A[0-9a-f]{64}\z/
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
    end

    create_timestamp :created_at
  end
end
