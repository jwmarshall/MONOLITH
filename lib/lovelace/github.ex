defmodule Lovelace.GitHub do
  @moduledoc "Read-only GitHub accounts and installation owners reusable across workspaces."
  use Ash.Domain

  resources do
    resource Lovelace.GitHub.Connection
    resource Lovelace.GitHub.Organization
    resource Lovelace.GitHub.WorkspaceOrganization

    resource Lovelace.GitHub.Operation do
      define :directory, action: :directory
      define :discover, action: :discover, args: [:connection_id]
      define :disconnect_account, action: :disconnect_account, args: [:connection_id]
      define :attach, action: :attach, args: [:workspace_id, :organization_id]
      define :detach, action: :detach, args: [:workspace_id, :organization_id]
      define :disconnect, action: :disconnect, args: [:organization_id]
      define :refresh, action: :refresh, args: [:organization_id]
      define :poll, action: :poll, args: [:organization_id, :generation]
    end
  end
end
