defmodule Monolith.GitHub.ClientOperation do
  @moduledoc false
  use Ash.Resource, domain: Monolith.GitHub, authorizers: [Ash.Policy.Authorizer]

  actions do
    action :client_status, :map do
      run {Monolith.GitHub.ClientSettings, operation: :status}
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

      run {Monolith.GitHub.ClientSettings, operation: :save}
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
    end
  end
end
