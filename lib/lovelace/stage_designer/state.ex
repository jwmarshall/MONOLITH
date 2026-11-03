defmodule Lovelace.StageDesigner.State do
  @moduledoc "Durable singleton reservation and bounded recent fallback candidates; not a catalog."
  use Ash.Resource,
    domain: Lovelace.StageDesigner,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "stage_designer_states"
  end

  actions do
    defaults [:read]

    create :initialize do
      accept []
      upsert? true
      upsert_fields []
    end

    # SQLite lacks expr_error used by atomic optimistic_lock. The record path still
    # applies version in the SQL WHERE clause and rejects concurrent stale writes.
    update :reserve do
      require_atomic? false
      atomic_upgrade? false
      accept [:last_attempt_at, :active_attempt_id]
      change set_attribute(:status, :generating)
      change optimistic_lock(:version)
    end

    update :publish do
      require_atomic? false
      atomic_upgrade? false
      accept [:history, :generated_at, :selected_digest, :scene_dates]
      change set_attribute(:status, :ready)
      change optimistic_lock(:version)
    end

    # Selection must not invalidate an already reserved generation. Storage
    # serializes this single-column update with publication and cleanup.
    update :select_scene do
      accept [:selected_digest]
    end

    update :fail do
      require_atomic? false
      atomic_upgrade? false
      accept []
      change set_attribute(:status, :failed)
      change optimistic_lock(:version)
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :stage_designer)
    end
  end

  attributes do
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      default 1
    end

    attribute :version, :integer do
      allow_nil? false
      default 0
    end

    attribute :status, :atom do
      constraints one_of: [:idle, :generating, :ready, :failed]
      allow_nil? false
      default :idle
    end

    attribute :active_attempt_id, :uuid
    attribute :last_attempt_at, :utc_datetime_usec
    attribute :generated_at, :utc_datetime_usec

    attribute :selected_digest, :string do
      constraints match: ~r/\A[0-9a-f]{64}\z/
    end

    attribute :scene_dates, :map do
      allow_nil? false
      default %{}
    end

    attribute :history, {:array, :string} do
      allow_nil? false
      default []
      constraints max_length: 7, items: [match: ~r/\A[0-9a-f]{64}\z/]
    end
  end
end
