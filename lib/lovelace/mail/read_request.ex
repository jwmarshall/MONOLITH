defmodule Lovelace.Mail.ReadRequest do
  @moduledoc "Short-lived protected mail-read input and safe trace state, never credentials or bodies."
  use Ash.Resource,
    domain: Lovelace.Mail,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "mail_read_requests"
  end

  actions do
    defaults [:read, :destroy]

    create :request do
      accept [:id, :account_id, :generation, :workspace_id, :kind, :input, :expires_at]
    end

    update :settle do
      accept [:state, :job_id, :outcome, :input]
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :account_id, :uuid, allow_nil?: false
    attribute :generation, :uuid, allow_nil?: false
    attribute :workspace_id, :uuid

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:page, :thread, :credentials]]

    attribute :input, :map, allow_nil?: false, sensitive?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :job_id, :integer

    attribute :state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :complete, :expired, :unavailable]]

    attribute :outcome, :map, sensitive?: true
    create_timestamp :created_at
  end
end
