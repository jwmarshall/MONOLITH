defmodule Lovelace.Mail.CacheEntry do
  @moduledoc "Sensitive, account-namespaced, seven-day on-demand cache; not a mail index."
  use Ash.Resource,
    domain: Lovelace.Mail,
    primary_read_warning?: false,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "gmail_cache_entries"

    references do
      reference :account, on_delete: :delete
    end
  end

  actions do
    read :read do
      primary? true
      argument :account_id, :uuid, allow_nil?: false
      filter expr(account_id == ^arg(:account_id))
    end

    create :store do
      accept [:account_id, :key, :payload, :bytes, :expires_at, :fetched_at, :generation]
      upsert? true
      upsert_identity :account_key
      upsert_fields [:payload, :bytes, :expires_at, :fetched_at, :generation]
    end

    destroy :evict
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Lovelace.Mail.Scope
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :key, :string, allow_nil?: false, sensitive?: true
    attribute :payload, :map, allow_nil?: false, sensitive?: true
    attribute :bytes, :integer, allow_nil?: false
    attribute :generation, :uuid, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :fetched_at, :utc_datetime_usec, allow_nil?: false
  end

  relationships do
    belongs_to :account, Lovelace.Mail.Account, allow_nil?: false
  end

  identities do
    identity :account_key, [:account_id, :key]
  end
end
