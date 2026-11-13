defmodule Monolith.ConnectionDiagnostics.Operation do
  @moduledoc false
  use Ash.Resource,
    domain: Monolith.ConnectionDiagnostics,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :request, :map do
      argument :provider, :atom,
        allow_nil?: false,
        constraints: [one_of: [:google, :gemini, :github]]

      run {Monolith.ConnectionDiagnostics.Operations, operation: :request}
    end

    action :observe, :map do
      argument :provider, :atom,
        allow_nil?: false,
        constraints: [one_of: [:google, :gemini, :github]]

      argument :id, :uuid, allow_nil?: false
      run {Monolith.ConnectionDiagnostics.Operations, operation: :observe}
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
    end
  end
end
