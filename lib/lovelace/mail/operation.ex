defmodule Lovelace.Mail.Operation do
  @moduledoc "Authorized orchestration actions. Network work never runs in a SQLite transaction."
  use Ash.Resource, domain: Lovelace.Mail, authorizers: [Ash.Policy.Authorizer]

  actions do
    action :link, :boolean do
      argument :workspace_id, :uuid, allow_nil?: false
      argument :account_id, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end

    action :unlink, :boolean do
      argument :workspace_id, :uuid, allow_nil?: false
      argument :account_id, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end

    action :disconnect, :map do
      argument :account_id, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end

    action :disconnect_status, :map do
      argument :account_id, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end

    action :finish_disconnect, :boolean do
      argument :operation_id, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end

    action :request_read, :map do
      argument :account_id, :uuid, allow_nil?: false
      argument :workspace_id, :uuid
      argument :generation, :uuid

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:page, :thread, :credentials]]

      argument :owner, :term, allow_nil?: false, sensitive?: true
      argument :query, :string, sensitive?: true, constraints: [max_length: 1024]
      argument :page_token, :string, sensitive?: true, constraints: [max_length: 2048]

      argument :thread_id, :string,
        sensitive?: true,
        constraints: [match: ~r/\A[a-zA-Z0-9_-]{1,128}\z/]

      argument :force, :boolean, default: false
      run Lovelace.Mail.Operations
    end

    action :read_status, :map do
      argument :operation_id, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end

    action :cancel_read, :boolean do
      argument :operation_id, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end

    action :perform_read, :boolean do
      argument :operation_id, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end

    action :check_credentials, :map do
      argument :account_id, :uuid, allow_nil?: false
      argument :generation, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end

    action :page, :map do
      argument :workspace_id, :uuid, allow_nil?: false
      argument :account_id, :uuid, allow_nil?: false
      argument :query, :string, constraints: [max_length: 1024], sensitive?: true
      argument :page_token, :string, constraints: [max_length: 2048], sensitive?: true
      argument :force, :boolean, default: false
      run Lovelace.Mail.Operations
    end

    action :thread, :map do
      argument :workspace_id, :uuid, allow_nil?: false
      argument :account_id, :uuid, allow_nil?: false

      argument :thread_id, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-zA-Z0-9_-]{1,128}\z/]

      argument :force, :boolean, default: false
      run Lovelace.Mail.Operations
    end

    action :account_page, :map do
      argument :account_id, :uuid, allow_nil?: false
      argument :query, :string, constraints: [max_length: 1024], sensitive?: true
      argument :page_token, :string, constraints: [max_length: 2048], sensitive?: true
      argument :force, :boolean, default: false
      run Lovelace.Mail.Operations
    end

    action :account_thread, :map do
      argument :account_id, :uuid, allow_nil?: false

      argument :thread_id, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-zA-Z0-9_-]{1,128}\z/]

      argument :force, :boolean, default: false
      run Lovelace.Mail.Operations
    end

    action :attachment, :map do
      argument :account_id, :uuid, allow_nil?: false

      argument :thread_id, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-zA-Z0-9_-]{1,128}\z/]

      argument :message_id, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-zA-Z0-9_-]{1,128}\z/]

      argument :attachment_id, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[-a-zA-Z0-9_.+=~]{1,2048}\z/]

      run Lovelace.Mail.Operations
    end

    action :poll, :map do
      argument :account_id, :uuid, allow_nil?: false
      argument :generation, :uuid, allow_nil?: false
      run Lovelace.Mail.Operations
    end
  end

  policies do
    policy action([
             :link,
             :unlink,
             :disconnect,
             :disconnect_status,
             :request_read,
             :read_status,
             :cancel_read,
             :check_credentials,
             :page,
             :thread,
             :account_page,
             :account_thread,
             :attachment
           ]) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end

    policy action(:finish_disconnect) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :mail_cleanup)
    end

    policy action(:perform_read) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :mail_read)
    end

    policy action(:poll) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :mail_service)
    end
  end
end
