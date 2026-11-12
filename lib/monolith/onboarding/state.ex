defmodule Monolith.Onboarding.State do
  @moduledoc "Owner-only guide position in the encrypted database; never Google verification or credentials."
  use Ash.Resource,
    domain: Monolith.Onboarding,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Monolith.Repo
    table "onboarding_states"
  end

  actions do
    defaults [:read]

    create :start do
      accept []
      upsert? true
      upsert_fields []
    end

    update :save_workspace do
      require_atomic? false
      accept [:workspace_id]
      validate present(:workspace_id)
      change set_attribute(:step, :project)
    end

    update :advance do
      require_atomic? false
      accept [:step]
      validate present(:workspace_id)
    end

    update :credentials_saved do
      require_atomic? false
      accept []
      validate present(:workspace_id)
      change set_attribute(:credentials_saved, true)
      change set_attribute(:step, :connect)
    end

    update :finish do
      require_atomic? false
      accept []
      validate present(:workspace_id)
      change set_attribute(:finished, true)
      change set_attribute(:step, :complete)
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
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
      default :workspace

      constraints one_of: [
                    :workspace,
                    :project,
                    :authentication,
                    :audience,
                    :client,
                    :connect,
                    :calendar,
                    :complete
                  ]
    end

    attribute :credentials_saved, :boolean, allow_nil?: false, default: false
    attribute :finished, :boolean, allow_nil?: false, default: false
  end

  relationships do
    belongs_to :workspace, Monolith.Workspaces.Workspace
  end
end
