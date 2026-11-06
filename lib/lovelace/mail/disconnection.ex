defmodule Lovelace.Mail.Disconnection do
  @moduledoc "Durable Google cleanup intent and independently observed local/remote outcomes."
  use Ash.Resource,
    domain: Lovelace.Mail,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "google_disconnections"
  end

  actions do
    defaults [:read]

    read :for_account do
      argument :account_id, :uuid, allow_nil?: false
      filter expr(account_id == ^arg(:account_id))
      prepare build(sort: [created_at: :desc], limit: 1)
    end

    create :accept do
      accept [:account_id, :generation]
    end

    update :outcome do
      accept [:remote, :credentials, :job_id, :state]
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
    attribute :account_id, :uuid, allow_nil?: false
    attribute :generation, :uuid, allow_nil?: false
    attribute :local_removed, :boolean, allow_nil?: false, default: true

    attribute :state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :complete, :superseded]]

    attribute :remote, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :claimed, :revoked, :unavailable, :uncertain]]

    attribute :credentials, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :removed, :failed, :superseded]]

    attribute :job_id, :integer
    create_timestamp :created_at
    update_timestamp :updated_at
  end
end
