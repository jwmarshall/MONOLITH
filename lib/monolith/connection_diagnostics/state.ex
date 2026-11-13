defmodule Monolith.ConnectionDiagnostics.State do
  @moduledoc "Exactly one non-secret diagnostic slot per supported provider."
  use Ash.Resource,
    domain: Monolith.ConnectionDiagnostics,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Monolith.Repo
    table "connection_diagnostic_states"
  end

  actions do
    defaults [:read]

    create :put do
      accept [:provider, :id, :status, :app_slug, :job_id, :requested_at]
      upsert? true
      upsert_fields [:id, :status, :app_slug, :job_id, :requested_at]
    end

    update :record do
      accept [:status, :app_slug, :job_id]
      argument :expected_id, :uuid, allow_nil?: false
      change filter(expr(id == ^arg(:expected_id) and status == :pending))
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :connection_diagnostics)
    end
  end

  attributes do
    attribute :provider, :atom do
      primary_key? true
      allow_nil? false
      constraints one_of: [:google, :gemini, :github]
    end

    attribute :id, :uuid, allow_nil?: false

    attribute :status, :atom do
      allow_nil? false
      constraints one_of: [:pending, :stored, :not_connected, :locked, :unavailable, :invalid]
    end

    attribute :app_slug, :string, constraints: [match: ~r/\A[a-z0-9][a-z0-9-]{0,99}\z/]
    attribute :job_id, :integer
    attribute :requested_at, :utc_datetime_usec, allow_nil?: false
  end
end
