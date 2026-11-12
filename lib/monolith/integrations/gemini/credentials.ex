defmodule Monolith.Integrations.Gemini.Credentials do
  @moduledoc "Safe local Gemini credential operations. Never validates with the provider or persists metadata."
  use Ash.Resource.Actions.Implementation

  alias Monolith.Integrations.Gemini.Keychain

  @type status :: :stored | :not_connected | :locked | :unavailable | :invalid

  @spec status() :: status()
  def status do
    case read_stored() do
      {:ok, _key} -> :stored
      {:error, :not_found} -> :not_connected
      {:error, :invalid_api_key} -> :invalid
      {:error, :locked} -> :locked
      _ -> :unavailable
    end
  end

  @spec read_key() :: {:ok, binary()} | {:error, :missing_api_key | :keychain_unavailable}
  def read_key do
    case read_stored() do
      {:ok, key} -> {:ok, key}
      {:error, reason} when reason in [:not_found, :invalid_api_key] -> {:error, :missing_api_key}
      _ -> {:error, :keychain_unavailable}
    end
  end

  @spec save(term()) :: {:ok, true} | {:error, atom()}
  def save(key) do
    with :ok <- validate_key(key) do
      case vault_call(:put, [Keychain.account(), key]) do
        :ok -> {:ok, true}
        error -> safe_error(error)
      end
    end
  end

  @spec delete() :: {:ok, true} | {:error, atom()}
  def delete do
    case vault_call(:delete, [Keychain.account()]) do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:ok, true}
      error -> safe_error(error)
    end
  end

  @doc false
  def validate_key(key) when is_binary(key) and byte_size(key) in 1..4096 do
    if String.valid?(key) and not Regex.match?(~r/\s/u, key),
      do: :ok,
      else: {:error, :invalid_api_key}
  end

  def validate_key(_), do: {:error, :invalid_api_key}

  @impl true
  def run(input, opts, _context) do
    case opts[:operation] do
      :status -> {:ok, status()}
      :save -> save(input.arguments.api_key)
      :delete -> delete()
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp read_stored do
    case vault_call(:get, [Keychain.account()]) do
      {:ok, key} ->
        case validate_key(key) do
          :ok -> {:ok, key}
          error -> error
        end

      error ->
        safe_error(error)
    end
  end

  defp vault_call(operation, args) do
    vault = Application.get_env(:monolith, :gemini_vault, Keychain)
    apply(vault, operation, args)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp safe_error({:error, reason}) when reason in [:not_found, :locked], do: {:error, reason}
  defp safe_error(_), do: {:error, :unavailable}
end
