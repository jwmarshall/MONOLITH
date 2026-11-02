defmodule Lovelace.Owner do
  @moduledoc "Local single-owner password unlock; unrelated to connected Gmail identities."
  use Ash.Domain

  resources do
    resource Lovelace.Owner.Credential do
      define :configure, action: :configure, args: [:password]
      define :configured, action: :configured
      define :unlock, action: :unlock, args: [:password, :client]
      define :read_credential, action: :read, get?: true, not_found_error?: false
    end

    resource Lovelace.Owner.Session do
      define :issue_session, action: :issue, args: [:digest, :expires_at]
      define :find_session, action: :read, get_by: [:digest], not_found_error?: false
      define :list_sessions, action: :read
      define :delete_session, action: :revoke
      define :verify_session, action: :verify, args: [:token]
      define :verify_digest, action: :verify_digest, args: [:digest]
      define :logout, action: :logout, args: [:token]
      define :lock_all, action: :lock_all
    end
  end
end
