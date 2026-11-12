defmodule Monolith.GitHub do
  @moduledoc "Read-only GitHub accounts and installation owners reusable across workspaces."
  use Ash.Domain

  resources do
    resource Monolith.GitHub.Connection
    resource Monolith.GitHub.Organization
    resource Monolith.GitHub.WorkspaceOrganization

    resource Monolith.GitHub.ClientOperation do
      define :client_status, action: :client_status

      define :save_client_credentials,
        action: :save_client_credentials,
        args: [:client_id, :client_secret, :app_slug]
    end

    resource Monolith.GitHub.Operation do
      define :directory, action: :directory
      define :home_summary, action: :home_summary
      define :discover, action: :discover, args: [:connection_id]
      define :run_discovery, action: :run_discovery, args: [:connection_id, :discovery_id]
      define :disconnect_account, action: :disconnect_account, args: [:connection_id]
      define :attach, action: :attach, args: [:workspace_id, :organization_id]

      define :attach_repositories,
        action: :attach_repositories,
        args: [:workspace_id, :organization_id, :repository_ids]

      define :detach, action: :detach, args: [:workspace_id, :organization_id]
      define :disconnect, action: :disconnect, args: [:organization_id]
      define :refresh, action: :refresh, args: [:organization_id]
      define :poll, action: :poll, args: [:organization_id, :generation]
    end
  end
end
