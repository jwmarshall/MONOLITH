defmodule Monolith.StageDesigner.Scene do
  @moduledoc "Durable content-addressed scenery catalog; not a retention queue."
  use Ash.Resource,
    domain: Monolith.StageDesigner,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @actor %{role: :stage_designer}
  @page_size 20

  sqlite do
    repo Monolith.Repo
    table "stage_designer_scenes"

    custom_indexes do
      index [:generated_at, :digest]
    end
  end

  actions do
    defaults [:read]

    create :publish do
      accept [:digest, :generated_at]
      upsert? true
      upsert_fields [:generated_at]
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :stage_designer)
    end
  end

  attributes do
    attribute :digest, :string do
      primary_key? true
      allow_nil? false
      constraints match: ~r/\A[0-9a-f]{64}\z/
    end

    # Legacy manifests have no timestamp for older images.
    attribute :generated_at, :utc_datetime_usec
  end

  def publish(digest, now) do
    __MODULE__
    |> Ash.Changeset.for_create(:publish, %{digest: digest, generated_at: now}, actor: @actor)
    |> Ash.create()
  end

  # Indexed, bounded lookup. Keep errors distinct from absence so cleanup fails closed.
  def registered(digest) do
    __MODULE__
    |> Ash.Query.filter(digest == ^digest)
    |> Ash.Query.select([:digest])
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: @actor)
    |> case do
      {:ok, nil} -> {:ok, false}
      {:ok, _scene} -> {:ok, true}
      {:error, error} -> {:error, error}
    end
  end

  def page_size, do: @page_size

  def page(page) do
    __MODULE__
    |> Ash.Query.sort(generated_at: :desc, digest: :desc)
    |> Ash.Query.limit(@page_size + 1)
    |> Ash.Query.offset((page - 1) * @page_size)
    |> Ash.read(actor: @actor)
    |> case do
      {:ok, scenes} -> {:ok, Enum.take(scenes, @page_size), length(scenes) > @page_size}
      {:error, error} -> {:error, error}
    end
  end
end
