defmodule Monolith.Onboarding.Operation do
  @moduledoc false
  use Ash.Resource,
    domain: Monolith.Onboarding,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :save_workspace, :struct do
      constraints instance_of: Monolith.Onboarding.State

      argument :name, :string do
        allow_nil? false
        constraints trim?: true, allow_empty?: false, max_length: 64
      end

      run Monolith.Onboarding.SaveWorkspace
    end

    action :save_credentials, :boolean do
      argument :client_id, :string do
        allow_nil? false
        sensitive? true
        constraints trim?: false
      end

      argument :client_secret, :string do
        allow_nil? false
        sensitive? true
        constraints trim?: false
      end

      run Monolith.Onboarding.Credentials
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
    end
  end
end
