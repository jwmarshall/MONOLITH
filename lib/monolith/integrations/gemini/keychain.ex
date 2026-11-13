defmodule Monolith.Integrations.Gemini.Keychain do
  @moduledoc "Application-wide Gemini credential, isolated from Gmail by Keychain service and UUID."
  @behaviour Monolith.Integrations.Google.Keychain

  alias Monolith.Security.{Keychain, Vault}

  @service "MONOLITH Gemini"
  @account "b26d050a-0729-4d79-a6bc-407cf660a7ea"

  @doc false
  def account, do: @account

  @impl true
  def get(@account), do: Vault.with_access(fn -> Keychain.get(@account, @service) end)
  def get(_), do: {:error, :invalid_account}

  @impl true
  def put(@account, value),
    do: Vault.with_access(fn -> Keychain.put(@account, value, @service) end)

  def put(_, _), do: {:error, :invalid_account}

  @impl true
  def delete(@account), do: Vault.with_access(fn -> Keychain.delete(@account, @service) end)
  def delete(_), do: {:error, :invalid_account}
end
