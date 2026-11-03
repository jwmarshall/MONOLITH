defmodule Lovelace.Mail do
  @moduledoc "Read-only Gmail connections, workspace membership and bounded on-demand mail."
  use Ash.Domain

  resources do
    resource Lovelace.Mail.Account do
      define :list_accounts, action: :read
      define :get_account, action: :read, get_by: [:id]
      define :find_account, action: :read, get_by: [:subject], not_found_error?: false
      define :save_connection, action: :connect
      define :update_account, action: :status
    end

    resource Lovelace.Mail.WorkspaceAccount do
      define :workspace_accounts, action: :read, args: [:workspace_id]
      define :list_workspace_accounts, action: :directory
      define :attach_account, action: :attach
      define :detach_account, action: :detach
    end

    resource Lovelace.Mail.CacheEntry

    resource Lovelace.Mail.Operation do
      define :link, action: :link, args: [:workspace_id, :account_id]
      define :unlink, action: :unlink, args: [:workspace_id, :account_id]
      define :disconnect, action: :disconnect, args: [:account_id]
      define :check_credentials, action: :check_credentials, args: [:account_id, :generation]
      define :mail_page, action: :page, args: [:workspace_id, :account_id]
      define :thread, action: :thread, args: [:workspace_id, :account_id, :thread_id]
      define :account_page, action: :account_page, args: [:account_id]
      define :account_thread, action: :account_thread, args: [:account_id, :thread_id]
      define :poll, action: :poll, args: [:account_id, :generation]
    end
  end
end
