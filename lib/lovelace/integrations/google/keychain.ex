defmodule Lovelace.Integrations.Google.Keychain do
  @moduledoc """
  Gmail credentials keyed by account UUID in LOVELACE's dedicated vault.

  All access holds a Vault lease. Native transport and migration operations belong
  to `Lovelace.Security.Keychain`; callers can inject a fake implementing this
  behaviour for provider tests without touching any macOS keychain.
  """

  @callback get(binary()) :: {:ok, binary()} | {:error, atom()}
  @callback put(binary(), binary()) :: :ok | {:error, atom()}
  @callback delete(binary()) :: :ok | {:error, atom()}

  alias Lovelace.Security.{Keychain, Vault}

  @service "LOVELACE Gmail"

  def get(account), do: Vault.with_access(fn -> Keychain.get(account, @service) end)
  def put(account, value), do: Vault.with_access(fn -> Keychain.put(account, value, @service) end)
  def delete(account), do: Vault.with_access(fn -> Keychain.delete(account, @service) end)
end
