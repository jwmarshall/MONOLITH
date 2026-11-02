defmodule Lovelace.Mail.WorkspaceAccount do
  @moduledoc "Workspace membership reuses a connection without merging mailboxes."
  use Ash.Resource,
    domain: Lovelace.Mail,
    primary_read_warning?: false,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "workspace_gmail_accounts"

    references do
      reference :workspace, on_delete: :delete
      reference :account, on_delete: :delete
    end
  end

  actions do
    read :read do
      primary? true
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
    end

    read :for_account do
      argument :account_id, :uuid, allow_nil?: false
      filter expr(account_id == ^arg(:account_id))
    end

    create :attach do
      accept [:workspace_id, :account_id]
      upsert? true
      upsert_identity :membership
      upsert_fields []
    end

    destroy :detach
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :created_at
  end

  relationships do
    belongs_to :workspace, Lovelace.Workspaces.Workspace, allow_nil?: false
    belongs_to :account, Lovelace.Mail.Account, allow_nil?: false
  end

  identities do
    identity :membership, [:workspace_id, :account_id]
  end
end
