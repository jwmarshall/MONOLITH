defmodule Lovelace.Google do
  @moduledoc "Shared local Google Desktop OAuth client settings, independent of account consent."
  use Ash.Domain

  resources do
    resource Lovelace.Google.Operation do
      define :client_status, action: :client_status

      define :save_client_credentials,
        action: :save_client_credentials,
        args: [:client_id, :client_secret]
    end
  end
end
