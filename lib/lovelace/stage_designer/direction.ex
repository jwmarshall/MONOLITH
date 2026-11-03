defmodule Lovelace.StageDesigner.Direction do
  @moduledoc "Owner-saved, application-wide guided scenery defaults. Reads never initialize it."
  use Ash.Resource,
    domain: Lovelace.StageDesigner,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Lovelace.StageDesigner.{DirectionOptions, Directions}

  sqlite do
    repo Lovelace.Repo
    table "stage_designer_directions"
  end

  actions do
    defaults [:read]

    create :save do
      accept [:subject, :setting, :light, :palette]
      upsert? true
      upsert_fields [:subject, :setting, :light, :palette]
    end

    action :scene_direction, :map do
      run {Directions, operation: :read}
    end

    action :save_scene_direction, :map do
      for field <- DirectionOptions.fields() do
        argument field.key, :string do
          allow_nil? false

          constraints trim?: false,
                      match:
                        Regex.compile!(
                          "\\A(?:" <> Enum.map_join(field.options, "|", &elem(&1, 1)) <> ")\\z"
                        )
        end
      end

      run {Directions, operation: :save}
    end
  end

  policies do
    policy action_type(:read) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
      authorize_if Lovelace.StageDesigner.ServiceActor
    end

    policy action([:save, :scene_direction, :save_scene_direction]) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end
  end

  validations do
    for field <- DirectionOptions.fields() do
      validate one_of(field.key, Enum.map(field.options, &elem(&1, 1)))
    end
  end

  attributes do
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      default 1
      constraints min: 1, max: 1
    end

    for field <- DirectionOptions.fields() do
      attribute field.key, :string do
        allow_nil? false
        constraints trim?: false
      end
    end
  end
end
