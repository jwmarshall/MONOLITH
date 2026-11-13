defmodule Monolith.GitHub.Operation do
  @moduledoc "Local-owner action boundary; provider work never holds a SQLite transaction."
  use Ash.Resource, domain: Monolith.GitHub, authorizers: [Ash.Policy.Authorizer]

  actions do
    action :directory, :map do
      run Monolith.GitHub.Operations
    end

    action :home_summary, :map do
      run Monolith.GitHub.Operations
    end

    action :discover, :map do
      argument :connection_id, :uuid, allow_nil?: false
      run Monolith.GitHub.Operations
    end

    action :run_discovery, :map do
      argument :connection_id, :uuid, allow_nil?: false
      argument :discovery_id, :uuid, allow_nil?: false
      run Monolith.GitHub.Operations
    end

    action :disconnect_account, :map do
      argument :connection_id, :uuid, allow_nil?: false
      run Monolith.GitHub.Operations
    end

    action :attach, :boolean do
      argument :workspace_id, :uuid, allow_nil?: false
      argument :organization_id, :uuid, allow_nil?: false
      run Monolith.GitHub.Operations
    end

    action :attach_repositories, :boolean do
      argument :workspace_id, :uuid, allow_nil?: false
      argument :organization_id, :uuid, allow_nil?: false

      argument :repository_ids, {:array, :string},
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 100, items: [max_length: 255]]

      run Monolith.GitHub.Operations
    end

    action :detach, :boolean do
      argument :workspace_id, :uuid, allow_nil?: false
      argument :organization_id, :uuid, allow_nil?: false
      run Monolith.GitHub.Operations
    end

    action :disconnect, :map do
      argument :organization_id, :uuid, allow_nil?: false
      run Monolith.GitHub.Operations
    end

    action :refresh, :map do
      argument :organization_id, :uuid, allow_nil?: false
      run Monolith.GitHub.Operations
    end

    action :poll, :map do
      argument :organization_id, :uuid, allow_nil?: false
      argument :generation, :uuid, allow_nil?: false
      run Monolith.GitHub.Operations
    end
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Monolith.Workspaces.LocalOwner
    end
  end
end
