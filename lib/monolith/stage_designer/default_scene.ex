defmodule Monolith.StageDesigner.DefaultScene do
  @moduledoc "One immutable bundled-scenery choice per local installation."
  use Ash.Resource,
    domain: Monolith.StageDesigner,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Monolith.StageDesigner.BundledScenes

  sqlite do
    repo Monolith.Repo
    table "stage_designer_defaults"
  end

  actions do
    defaults [:read]

    create :initialize do
      accept []
      upsert? true
      upsert_fields []
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :stage_designer)
    end
  end

  validations do
    validate one_of(:digest, BundledScenes.digests())
  end

  attributes do
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      default 1
    end

    attribute :digest, :string do
      allow_nil? false
      default &BundledScenes.random_digest/0
    end
  end
end
