defmodule Monolith.GitHub.WorkspaceOrganization do
  @moduledoc "Workspace membership, independent of the installation owner's shared GitHub account."
  use Ash.Resource,
    domain: Monolith.GitHub,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Monolith.Repo
    table "workspace_github_organizations"

    references do
      reference :workspace, on_delete: :delete
      reference :organization, on_delete: :delete
    end
  end

  actions do
    read :read do
      primary? true
    end

    create :attach do
      accept [:workspace_id, :organization_id, :repository_ids]
      upsert? true
      upsert_identity :membership
      upsert_fields [:repository_ids]
    end

    destroy :detach
  end

  policies do
    policy action_type(:read) do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
      authorize_if actor_attribute_equals(:role, :github_service)
    end

    policy action_type([:create, :destroy]) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :github_service)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :repository_ids, {:array, :string},
      default: [],
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 100, items: [max_length: 255]]

    create_timestamp :created_at
  end

  relationships do
    belongs_to :workspace, Monolith.Workspaces.Workspace, allow_nil?: false, public?: true
    belongs_to :organization, Monolith.GitHub.Organization, allow_nil?: false, public?: true
  end

  identities do
    identity :membership, [:workspace_id, :organization_id]
  end
end
