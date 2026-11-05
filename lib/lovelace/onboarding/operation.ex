defmodule Lovelace.Onboarding.Operation do
  @moduledoc false
  use Ash.Resource,
    domain: Lovelace.Onboarding,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :save_workspace, :struct do
      constraints instance_of: Lovelace.Onboarding.State

      argument :name, :string do
        allow_nil? false
        constraints trim?: true, allow_empty?: false, max_length: 64
      end

      run Lovelace.Onboarding.SaveWorkspace
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

      run Lovelace.Onboarding.Credentials
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end
  end
end
