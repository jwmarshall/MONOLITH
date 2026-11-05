defmodule Lovelace.Workspaces.Workspace do
  @moduledoc """
  A saved workspace. The local-owner actor is a single-owner loopback capability,
  not authentication or a connected Gmail identity.
  """
  use Ash.Resource,
    domain: Lovelace.Workspaces,
    # Every read, including get-by-id, deliberately uses the same stable order.
    primary_read_warning?: false,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "workspaces"
  end

  actions do
    read :read do
      primary? true
      prepare build(sort: [created_at: :asc, id: :asc])
    end

    create :create do
      primary? true
      accept [:name]
    end

    update :rename do
      accept [:name]
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints trim?: true, allow_empty?: false, max_length: 64
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end
end
