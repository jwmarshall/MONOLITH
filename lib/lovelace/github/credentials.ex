defmodule Lovelace.GitHub.Credentials do
  @moduledoc "Account credential lifecycle and durable, one-shot refresh reservation."
  import Lovelace.GitHub.Store
  import Lovelace.GitHub.Coordination, only: [state: 1]
  alias Lovelace.GitHub.{ClientCredentials, Connection, Coordination}
  alias Lovelace.Security.Vault

  # Called only while the configuration writer holds the coordination owner's state lock.
  def client_changed do
    Enum.each(connections(), fn account ->
      if account.status != :disconnected,
        do: fence_connection(account.id, :reauthorization, :reconnect)
    end)

    :ok
  end

  def access_token(connection_id) do
    case access_credential(connection_id) do
      {:ok, token, _account} -> {:ok, token}
      error -> error
    end
  end

  def access_credential(connection_id, expected_generation \\ nil) do
    safely(fn ->
      Vault.with_access(fn ->
        serialized_credential(connection_id, expected_generation)
      end)
    end)
  end

  defp serialized_credential(connection_id, expected_generation) do
    Coordination.credential(connection_id, fn ->
      intent = state(fn -> token_intent(connection_id, expected_generation) end)

      case intent do
        {:ok, token, account} -> {:ok, token, account}
        {:rotate, connection, refresh} -> rotate(connection, refresh)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def disconnect_account(id) do
    case connection(id) do
      nil ->
        {:error, :unavailable}

      account ->
        {:ok, disconnected} = transact(fn -> disconnect_account_records(account) end)
        finish_delete(disconnected, vault().delete(account.id))
    end
  end

  defp disconnect_account_records(account) do
    current = transition!(account, %{status: :disconnected, generation: uuid(), last_error: nil})

    for org <- account_owners(account.id) do
      update!(org, cleared(:disconnected, nil))
      remove_memberships(org.id)
    end

    current
  end

  defp token_intent(id, expected_generation) do
    case connection(id) do
      %Connection{generation: generation}
      when not is_nil(expected_generation) and generation != expected_generation ->
        {:error, :reconnect}

      %Connection{status: :ready} = account ->
        ready_token_intent(account)

      %Connection{status: :refreshing} ->
        fence_connection(id, :reauthorization, :reconnect)
        {:error, :reconnect}

      _ ->
        {:error, :reconnect}
    end
  end

  defp ready_token_intent(account) do
    case read_bundle(account.id) do
      {:ok, bundle} ->
        token_bundle_intent(account, bundle)

      {:error, :missing_credentials} ->
        fence_connection(account.id, :reauthorization, :keychain)
        {:error, :keychain}

      _ ->
        {:error, :keychain}
    end
  end

  defp token_bundle_intent(account, bundle) do
    cond do
      not current_client_generation?(bundle["client_generation"]) ->
        fence_connection(account.id, :reauthorization, :reconnect)
        {:error, :reconnect}

      bundle["refresh_expires_at"] <= unix() ->
        fence_connection(account.id, :reauthorization, :expired)
        {:error, :expired}

      bundle["expires_at"] > unix() + 60 ->
        {:ok, bundle["access_token"], account}

      true ->
        # Durable one-shot intent is committed BEFORE rotating HTTP, including crash paths.
        reserved =
          transition!(account, %{
            status: :refreshing,
            generation: uuid(),
            last_error: :reconnect
          })

        {:rotate, reserved, {bundle["refresh_token"], bundle["client_generation"]}}
    end
  end

  defp rotate(expected, {refresh, generation}) do
    result =
      safely(fn ->
        with {:ok, client} <- ClientCredentials.current(),
             true <- client.generation == generation,
             {:ok, bundle} <-
               provider().refresh_token(client.client_id, client.client_secret, refresh),
             {:ok, stored} <- encode_bundle(Map.put(bundle, :client_generation, generation)) do
          {:ok, bundle.access_token, stored}
        else
          {:error, reason} -> {:error, safe_error(reason)}
          _ -> {:error, :provider}
        end
      end)

    state(fn -> finish_rotation(expected, result) end)
  end

  defp finish_rotation(expected, result) do
    case connection(expected.id) do
      %Connection{status: :refreshing, generation: generation} = account
      when generation == expected.generation ->
        commit_rotation(account, result)

      _ ->
        {:error, :reconnect}
    end
  end

  defp commit_rotation(account, result) do
    with {:ok, token, stored} <- result,
         :ok <- current_client_bundle(stored),
         :ok <- put_token(account.id, stored) do
      current = transition!(account, %{status: :ready, last_error: nil})
      {:ok, token, current}
    else
      {:error, reason} ->
        fence_connection(account.id, :reauthorization, safe_error(reason))
        {:error, safe_error(reason)}
    end
  end

  def encode_bundle(bundle) when is_map(bundle) do
    if valid_token?(bundle[:access_token]) and valid_token?(bundle[:refresh_token]) and
         is_integer(bundle[:expires_in]) and bundle.expires_in > 0 and
         is_integer(bundle[:refresh_token_expires_in]) and bundle.refresh_token_expires_in > 0 and
         is_binary(bundle[:client_generation]) do
      {:ok,
       Jason.encode!(%{
         access_token: bundle.access_token,
         refresh_token: bundle.refresh_token,
         client_generation: bundle.client_generation,
         expires_at: unix() + bundle.expires_in,
         refresh_expires_at: unix() + bundle.refresh_token_expires_in
       })}
    else
      {:error, :provider}
    end
  end

  defp read_bundle(id) do
    with {:ok, value} when is_binary(value) and byte_size(value) <= 16_384 <- vault().get(id),
         {:ok, bundle} when is_map(bundle) <- Jason.decode(value),
         true <- valid_token?(bundle["access_token"]) and valid_token?(bundle["refresh_token"]),
         true <- is_integer(bundle["expires_at"]) and is_integer(bundle["refresh_expires_at"]) do
      {:ok, bundle}
    else
      {:error, :not_found} -> {:error, :missing_credentials}
      {:error, reason} when is_atom(reason) -> {:error, :keychain}
      _ -> {:error, :missing_credentials}
    end
  end

  defp valid_token?(token),
    do:
      is_binary(token) and byte_size(token) in 1..4096 and
        Regex.match?(~r/\A[A-Za-z0-9_\-.]+\z/, token)

  def current_client_bundle(stored) do
    with {:ok, bundle} <- Jason.decode(stored),
         true <- current_client_generation?(bundle["client_generation"]) do
      :ok
    else
      _ -> {:error, :reconnect}
    end
  end

  defp current_client_generation?(generation) when is_binary(generation) do
    case ClientCredentials.current() do
      {:ok, %{generation: ^generation}} -> true
      _ -> false
    end
  end

  defp current_client_generation?(_), do: false
end
