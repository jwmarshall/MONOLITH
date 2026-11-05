defmodule Lovelace.GitHub.ClientOperation do
  @moduledoc false
  use Ash.Resource, domain: Lovelace.GitHub, authorizers: [Ash.Policy.Authorizer]

  actions do
    action :client_status, :map do
      run {Lovelace.GitHub.ClientSettings, operation: :status}
    end

    action :save_client_credentials, :boolean do
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

      argument :app_slug, :string do
        allow_nil? false
        sensitive? true
        constraints trim?: false
      end

      run {Lovelace.GitHub.ClientSettings, operation: :save}
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end
  end
end
