defmodule Monolith.Integrations.Google.ClientCredentials do
  @moduledoc "Local Google OAuth client credentials, stored only in the dedicated vault."

  alias Monolith.Security.{Keychain, Vault}

  @account "710dd510-61ed-4e6a-975c-78ce13f5d6e2"
  @service "MONOLITH Google OAuth"
  @max_json 16 * 1024

  @type status :: :stored | :not_connected | :locked | :invalid | :unavailable

  @spec status() :: status()
  def status do
    case read_stored() do
      {:ok, _credentials} -> :stored
      {:error, :not_found} -> :not_connected
      {:error, :invalid_configuration} -> :invalid
      {:error, :locked} -> :locked
      _ -> :unavailable
    end
  end

  # Provider callers historically treat a missing item as invalid configuration.
  def read do
    case read_stored() do
      {:error, :not_found} -> {:error, :invalid_configuration}
      result -> result
    end
  end

  defp read_stored do
    access(fn ->
      case keychain().get(@account, @service) do
        {:ok, json} when is_binary(json) and byte_size(json) <= @max_json -> decode(json)
        {:ok, _} -> {:error, :invalid_configuration}
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> safe_error(reason)
        _ -> {:error, :unavailable}
      end
    end)
  end

  def save(client_id, client_secret) do
    with :ok <- validate(client_id, client_secret) do
      %{client_id: client_id, client_secret: client_secret}
      |> Jason.encode!()
      |> save_json()
    end
  end

  defp save_json(json) when byte_size(json) <= @max_json, do: access(fn -> store(json) end)
  defp save_json(_), do: {:error, :invalid_configuration}

  defp store(json) do
    case keychain().put(@account, json, @service) do
      :ok -> :ok
      {:error, reason} -> safe_error(reason)
      _ -> {:error, :unavailable}
    end
  end

  def delete do
    access(fn ->
      case keychain().delete(@account, @service) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> safe_error(reason)
        _ -> {:error, :unavailable}
      end
    end)
  end

  def validate(client_id, client_secret) do
    if valid?(client_id) and valid?(client_secret),
      do: :ok,
      else: {:error, :invalid_configuration}
  end

  defp decode(json) do
    with {:ok, %{"client_id" => id, "client_secret" => secret}} <- Jason.decode(json),
         :ok <- validate(id, secret) do
      {:ok, %{client_id: id, client_secret: secret}}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp valid?(value) when is_binary(value) and byte_size(value) in 1..8192,
    do: String.valid?(value) and not Regex.match?(~r/[\s\x00]/u, value)

  defp valid?(_), do: false

  defp keychain,
    do: Application.get_env(:monolith, :google_client_keychain, Keychain)

  defp access(fun) do
    Vault.with_access(fun)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp safe_error(:not_found), do: {:error, :invalid_configuration}
  defp safe_error(:locked), do: {:error, :locked}
  defp safe_error(_), do: {:error, :unavailable}
end
