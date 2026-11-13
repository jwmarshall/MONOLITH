defmodule Monolith.Google.Operation do
  @moduledoc false
  use Ash.Resource,
    domain: Monolith.Google,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :client_status, :atom do
      run {Monolith.Google.Credentials, operation: :status}
    end

    action :save_client_credentials, :boolean do
      argument :client_id, :string do
        allow_nil? false
        sensitive? true
        # Validate in the implementation: constraint errors can retain raw values.
        constraints trim?: false
      end

      argument :client_secret, :string do
        allow_nil? false
        sensitive? true
        constraints trim?: false
      end

      run {Monolith.Google.Credentials, operation: :save}
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
    end
  end
end
