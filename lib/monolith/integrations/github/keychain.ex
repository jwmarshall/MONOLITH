defmodule Monolith.Integrations.GitHub.Keychain do
  @moduledoc """
  GitHub token bundles keyed by account-connection UUID in MONOLITH's dedicated vault.

  All access holds a Vault lease. Native transport belongs to
  `Monolith.Security.Keychain`; callers can inject a fake implementing this
  behaviour without touching any macOS keychain.
  """

  @callback get(binary()) :: {:ok, binary()} | {:error, atom()}
  @callback put(binary(), binary()) :: :ok | {:error, atom()}
  @callback delete(binary()) :: :ok | {:error, atom()}

  alias Monolith.Security.{Keychain, Vault}

  @service "MONOLITH GitHub"

  def get(id), do: Vault.with_access(fn -> Keychain.get(id, @service) end)

  def put(id, value),
    do: Vault.with_access(fn -> Keychain.put(id, value, @service) end)

  def delete(id),
    do: Vault.with_access(fn -> Keychain.delete(id, @service) end)
end
