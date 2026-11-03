defmodule Lovelace.Integrations.Gemini.Keychain do
  @moduledoc "Application-wide Gemini credential, isolated from Gmail by Keychain service and UUID."
  @behaviour Lovelace.Integrations.Google.Keychain

  alias Lovelace.Integrations.Google.Keychain

  @service "LOVELACE Gemini"
  @account "b26d050a-0729-4d79-a6bc-407cf660a7ea"

  @doc false
  def account, do: @account

  @impl true
  def get(@account), do: Keychain.get(@account, @service)
  def get(_), do: {:error, :invalid_account}

  @impl true
  def put(@account, value), do: Keychain.put(@account, value, @service)
  def put(_, _), do: {:error, :invalid_account}

  @impl true
  def delete(@account), do: Keychain.delete(@account, @service)
  def delete(_), do: {:error, :invalid_account}
end
