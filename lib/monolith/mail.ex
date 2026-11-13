defmodule Monolith.Mail do
  @moduledoc "Read-only Gmail connections, workspace membership and bounded on-demand mail."
  use Ash.Domain

  resources do
    resource Monolith.Mail.Account do
      define :list_accounts, action: :read
      define :get_account, action: :read, get_by: [:id]
      define :find_account, action: :read, get_by: [:subject], not_found_error?: false
      define :save_connection, action: :connect
      define :update_account, action: :status
    end

    resource Monolith.Mail.WorkspaceAccount do
      define :workspace_accounts, action: :read, args: [:workspace_id]
      define :list_workspace_accounts, action: :directory
      define :attach_account, action: :attach
      define :detach_account, action: :detach
    end

    resource Monolith.Mail.CacheEntry
    resource Monolith.Mail.Disconnection
    resource Monolith.Mail.ReadRequest

    resource Monolith.Mail.Summary do
      define :home_summary, action: :home_summary
    end

    resource Monolith.Mail.Operation do
      define :link, action: :link, args: [:workspace_id, :account_id]
      define :unlink, action: :unlink, args: [:workspace_id, :account_id]
      define :disconnect, action: :disconnect, args: [:account_id]
      define :disconnect_status, action: :disconnect_status, args: [:account_id]
      define :finish_disconnect, action: :finish_disconnect, args: [:operation_id]
      define :request_read, action: :request_read
      define :read_status, action: :read_status, args: [:operation_id]
      define :cancel_read, action: :cancel_read, args: [:operation_id]
      define :perform_read, action: :perform_read, args: [:operation_id]
      define :check_credentials, action: :check_credentials, args: [:account_id, :generation]
      define :mail_page, action: :page, args: [:workspace_id, :account_id]
      define :thread, action: :thread, args: [:workspace_id, :account_id, :thread_id]
      define :account_page, action: :account_page, args: [:account_id]
      define :account_thread, action: :account_thread, args: [:account_id, :thread_id]

      define :attachment,
        action: :attachment,
        args: [:account_id, :thread_id, :message_id, :attachment_id]

      define :poll, action: :poll, args: [:account_id, :generation]
    end
  end
end
