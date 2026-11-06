defmodule Lovelace.StageDesigner.Attempt do
  @moduledoc "Permanent, app-wide generation history, independent of Oban retention."
  use Ash.Resource,
    domain: Lovelace.StageDesigner,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query
  @actor %{role: :stage_designer}

  sqlite do
    repo Lovelace.Repo
    table "stage_designer_attempts"

    custom_indexes do
      index [:inserted_at, :id]
      index [:status, :updated_at]
      index [:cleanup, :updated_at]
    end
  end

  actions do
    defaults [:read]

    create :reserve do
      accept [
        :id,
        :reservation_version,
        :source,
        :prompt,
        :model,
        :aspect_ratio,
        :image_size,
        :timeout_seconds,
        :inserted_at
      ]
    end

    update :record do
      require_atomic? false
      atomic_upgrade? false

      accept [
        :status,
        :provider_id,
        :failure,
        :last_checked_at,
        :completed_at,
        :digest,
        :cleanup,
        :cleanup_error,
        :acknowledged_at,
        :poll_count,
        :tracking_errors
      ]

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
    uuid_primary_key :id, writable?: true
    attribute :version, :integer, allow_nil?: false, default: 0
    attribute :reservation_version, :integer, allow_nil?: false

    attribute :source, :atom do
      allow_nil? false
      constraints one_of: [:manual, :startup, :operator, :legacy]
    end

    attribute :status, :atom do
      allow_nil? false
      default :queued

      constraints one_of: [
                    :queued,
                    :submitting,
                    :rendering,
                    :tracking_paused,
                    :completed,
                    :failed,
                    :unknown,
                    :abandoned
                  ]
    end

    attribute :prompt, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [trim?: false, allow_empty?: true, max_length: 8000]

    attribute :model, :string, allow_nil?: false
    attribute :aspect_ratio, :string, allow_nil?: false
    attribute :image_size, :string, allow_nil?: false
    attribute :timeout_seconds, :integer, allow_nil?: false, default: 120
    attribute :provider_id, :string, sensitive?: true, constraints: [max_length: 512]
    attribute :failure, :string, constraints: [max_length: 1000]
    attribute :poll_count, :integer, allow_nil?: false, default: 0
    attribute :tracking_errors, :integer, allow_nil?: false, default: 0
    attribute :last_checked_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :acknowledged_at, :utc_datetime_usec
    attribute :digest, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :cleanup, :atom do
      allow_nil? false
      default :none
      constraints one_of: [:none, :pending, :completed, :failed]
    end

    attribute :cleanup_error, :string, constraints: [max_length: 1000]
    create_timestamp :inserted_at, writable?: true
    update_timestamp :updated_at
  end

  def get(id), do: Ash.get(__MODULE__, id, actor: @actor, not_found_error?: false)

  def create(attrs) do
    __MODULE__
    |> Ash.Changeset.for_create(:reserve, attrs, actor: @actor)
    |> Ash.create()
  end

  def record(attempt, attrs) do
    attempt
    |> Ash.Changeset.for_update(:record, attrs, actor: @actor)
    |> Ash.update()
  end

  def page(page) do
    __MODULE__
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(21)
    |> Ash.Query.offset((page - 1) * 20)
    |> Ash.read(actor: @actor)
  end

  def recoverable do
    __MODULE__
    |> Ash.Query.filter(status in [:queued, :submitting, :rendering] or cleanup == :pending)
    |> Ash.Query.sort(updated_at: :asc, id: :asc)
    |> Ash.Query.limit(20)
    |> Ash.read(actor: @actor)
  end
end
