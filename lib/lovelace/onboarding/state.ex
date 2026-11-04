defmodule Lovelace.Onboarding.State do
  @moduledoc "Owner-only guide position in the encrypted database; never Google verification or credentials."
  use Ash.Resource,
    domain: Lovelace.Onboarding,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "onboarding_states"
  end

  actions do
    defaults [:read]

    create :start do
      accept []
      upsert? true
      upsert_fields []
    end

    update :advance do
      accept [:step]
    end

    update :credentials_saved do
      accept []
      change set_attribute(:credentials_saved, true)
      change set_attribute(:step, :connect)
    end

    update :finish do
      accept []
      change set_attribute(:finished, true)
      change set_attribute(:step, :complete)
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end
  end

  attributes do
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      default 1
    end

    attribute :step, :atom do
      allow_nil? false
      default :project
      constraints one_of: [:project, :authentication, :audience, :client, :connect, :complete]
    end

    attribute :credentials_saved, :boolean, allow_nil?: false, default: false
    attribute :finished, :boolean, allow_nil?: false, default: false
  end
end
