defmodule Lovelace.Workspaces do
  @moduledoc "Saved workspaces for the local owner, independent of mailbox accounts."
  use Ash.Domain

  resources do
    resource Lovelace.Workspaces.Workspace do
      define :list_workspaces, action: :read
      define :get_workspace, action: :read, get_by: [:id], not_found_error?: false
      define :create_workspace, action: :create, args: [:name]
      define :rename_workspace, action: :rename, args: [:name]
    end
  end
end
