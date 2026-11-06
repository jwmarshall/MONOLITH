defmodule Lovelace.OAuth.Exchange do
  @moduledoc "Secret-free bounded OAuth correlation with a non-replayable exchange claim."
  use Ash.Resource,
    domain: Lovelace.OAuth,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @service %{role: :oauth_service}
  require Ash.Query

  sqlite do
    repo Lovelace.Repo
    table "oauth_exchanges"

    custom_indexes do
      index [:inserted_at, :id]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :reserve do
      accept [:id, :provider]
    end

    update :record do
      require_atomic? false
      atomic_upgrade? false
      accept [:status, :outcome, :job_id]
      change optimistic_lock(:version)
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :oauth_service)
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :provider, :atom, allow_nil?: false, constraints: [one_of: [:google, :github]]
    attribute :version, :integer, allow_nil?: false, default: 0
    attribute :job_id, :integer

    attribute :status, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [one_of: [:queued, :claimed, :completed, :failed]]

    attribute :outcome, :atom,
      constraints: [one_of: [:connected, :reauthorize, :cancelled, :unavailable, :unknown]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  def get(id), do: Ash.get(__MODULE__, id, actor: @service, not_found_error?: false)

  def reserve(id, provider) do
    __MODULE__
    |> Ash.Changeset.for_create(:reserve, %{id: id, provider: provider}, actor: @service)
    |> Ash.create()
  end

  def record(exchange, attrs) do
    exchange
    |> Ash.Changeset.for_update(:record, attrs, actor: @service)
    |> Ash.update()
  end

  # Secret holders expire after ten minutes. Retain safe correlations for one
  # day, with a hard row cap; deleted IDs cannot execute without their holder.
  def capacity do
    cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)

    expired =
      __MODULE__
      |> Ash.Query.filter(inserted_at < ^cutoff)
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: @service)

    Enum.each(expired, &Ash.destroy!(&1, actor: @service))
    rows = __MODULE__ |> Ash.Query.limit(1000) |> Ash.read!(actor: @service)
    if length(rows) < 1000, do: :ok, else: {:error, :busy}
  end
end
