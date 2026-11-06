defmodule Lovelace.GitHub.Auth do
  @moduledoc "Protected bounded session-bound secrets for Oban-owned one-use GitHub authorization."
  use GenServer
  alias Lovelace.GitHub.{Callback, ClientCredentials, Operations}
  alias Lovelace.Owner
  alias Lovelace.Owner.Actions
  alias Lovelace.Security.{Secret, Vault}
  @owner %{role: :local_owner}
  @service [actor: %{role: :owner_auth_service}]
  @limit 16
  @ttl 600_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def begin(session) when is_binary(session), do: call({:begin, %Secret{value: session}})
  def begin(_), do: {:error, :unavailable}

  def complete(session, params) do
    with {:ok, %{id: id}} <- admit(session, params), do: Lovelace.OAuth.await(id, __MODULE__)
  end

  def admit(session, params) when is_binary(session) and is_map(params) do
    with {:ok, _} <- Owner.verify_session(session),
         {:ok, id} <- call({:prepare, %Secret{value: {session, params}}}),
         {:ok, reference} <- enqueue(id) do
      {:ok, reference}
    else
      _ -> {:error, :expired}
    end
  end

  def admit(_, _), do: {:error, :expired}

  defp enqueue(id) do
    case Lovelace.OAuth.exchange(id, :github, actor: @owner) do
      {:ok, _} = accepted ->
        accepted

      _ ->
        call({:settle, id, {:error, :unavailable}})
        {:error, :unavailable}
    end
  end

  def cancel(session) when is_binary(session), do: call({:cancel, Actions.digest(session)})
  def cancel(_), do: {:error, :unavailable}
  def status(digest) when is_binary(digest), do: call({:status, digest}, %{status: :idle})
  def status(_), do: %{status: :idle}
  def result(id), do: call({:result, id})
  def callback_url, do: Callback.url()

  def execute(id) do
    result =
      guarded_access(fn ->
        case call({:claim, id}) do
          {:ok, %Secret{value: attempt}} -> exchange(attempt, attempt.params)
          _ -> {:error, :expired}
        end
      end)

    call({:settle, id, result})
    result
  end

  defp configuration(session), do: guarded_access(fn -> authorization_configuration(session) end)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:begin, %Secret{value: session}}, _, attempts) do
    attempts = make_room(prune(attempts), Actions.digest(session))
    key = Actions.digest(session)

    cond do
      public(attempts[key]).status == :exchanging ->
        {:reply, {:error, :busy}, attempts}

      map_size(attempts) >= @limit and not Map.has_key?(attempts, key) ->
        {:reply, {:error, :busy}, attempts}

      true ->
        case configuration(session) do
          {:ok, client, uri, fence} ->
            state = random()
            verifier = random()

            attempt = %{
              id: Ash.UUID.generate(),
              session: %Secret{value: session},
              state_digest: Actions.digest(state),
              verifier: %Secret{value: verifier},
              client_generation: client.generation,
              callback_url: uri,
              fence: fence,
              expires: now() + @ttl,
              status: :pending
            }

            query =
              URI.encode_query(%{
                client_id: client.client_id,
                redirect_uri: uri,
                state: state,
                scope: "offline_access",
                code_challenge_method: "S256",
                code_challenge:
                  Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
                prompt: "select_account"
              })

            {:reply, {:ok, "https://github.com/login/oauth/authorize?" <> query},
             Map.put(attempts, key, attempt)}

          error ->
            {:reply, error, attempts}
        end
    end
  end

  def handle_call({:prepare, %Secret{value: {session, params}}}, _, attempts) do
    key = Actions.digest(session)

    case prune(attempts)[key] do
      %{status: :pending} = attempt ->
        if valid_session?(session) and is_binary(params["state"]) and
             Actions.digest(params["state"]) == attempt.state_digest do
          prepared = Map.merge(attempt, %{status: :queued, params: %Secret{value: params}})
          {:reply, {:ok, attempt.id}, Map.put(attempts, key, prepared)}
        else
          {:reply, {:error, :expired}, attempts}
        end

      _ ->
        {:reply, {:error, :expired}, attempts}
    end
  end

  def handle_call({:claim, id}, _, attempts) do
    case find(prune(attempts), id) do
      {key, %{status: :queued} = attempt} ->
        if current?(attempt) do
          secret = Map.put(attempt, :params, attempt.params.value)

          claimed =
            Map.drop(attempt, [:params, :verifier, :state_digest])
            |> Map.put(:status, :exchanging)

          {:reply, {:ok, %Secret{value: secret}}, Map.put(attempts, key, claimed)}
        else
          {:reply, {:error, :expired}, Map.put(attempts, key, terminal(attempt, :failed))}
        end

      _ ->
        {:reply, {:error, :expired}, attempts}
    end
  end

  def handle_call({:commit, id, %Secret{value: fun}}, _, attempts) do
    case find(attempts, id) do
      {key, %{status: :exchanging} = attempt} ->
        result = if current?(attempt), do: guarded_access(fun), else: {:error, :expired}

        next =
          if match?({:ok, _}, result),
            do: terminal(attempt, :connected) |> Map.put(:result, result),
            else: attempt

        {:reply, result, Map.put(attempts, key, next)}

      _ ->
        {:reply, {:error, :expired}, attempts}
    end
  end

  def handle_call({:cancel, key}, _, attempts) do
    case attempts[key] do
      %{status: :connected} ->
        {:reply, {:error, :already_authorized}, attempts}

      nil ->
        {:reply, :ok, attempts}

      attempt ->
        {:reply, :ok,
         Map.put(
           attempts,
           key,
           terminal(attempt, :cancelled) |> Map.put(:result, {:error, :expired})
         )}
    end
  end

  def handle_call({:settle, id, result}, _, attempts) do
    case find(attempts, id) do
      {_, %{status: status}} when status in [:connected, :cancelled] ->
        {:reply, :ok, attempts}

      {key, attempt} ->
        status = if match?({:ok, _}, result), do: :connected, else: :failed

        {:reply, :ok,
         Map.put(attempts, key, terminal(attempt, status) |> Map.put(:result, result))}

      _ ->
        {:reply, :ok, attempts}
    end
  end

  def handle_call({:result, id}, _, attempts) do
    result =
      case find(prune(attempts), id) do
        {_, %{result: result}} -> result
        {_, _} -> :pending
        _ -> {:error, :expired}
      end

    {:reply, result, prune(attempts)}
  end

  def handle_call({:status, key}, _, attempts) do
    attempts = prune(attempts)

    reply =
      if match?({:ok, _}, Owner.verify_digest(key, @service)),
        do: public(attempts[key]),
        else: %{status: :idle}

    {:reply, reply, attempts}
  end

  @impl true
  def format_status(_), do: %{state: :redacted, message: :redacted, reason: :redacted}

  defp authorization_configuration(session) do
    with true <- valid_session?(session),
         {:ok, client} <- ClientCredentials.current(),
         uri when is_binary(uri) <- callback_url() do
      {:ok, client, uri, Operations.authorization_fence()}
    else
      _ -> {:error, :configuration}
    end
  end

  defp exchange(_, %{"error" => "access_denied"}), do: {:error, :denied}

  defp exchange(attempt, params) do
    with true <- is_nil(params["error"]),
         code when is_binary(code) and byte_size(code) in 1..4096 <- params["code"],
         true <- current?(attempt),
         {:ok, client} <- ClientCredentials.current(),
         true <- client.generation == attempt.client_generation,
         {:ok, bundle} <-
           provider().exchange_code(
             client.client_id,
             client.client_secret,
             code,
             attempt.verifier.value,
             attempt.callback_url
           ) do
      Operations.authorize(
        attempt.session.value,
        Map.put(bundle, :client_generation, client.generation),
        fn fun -> call({:commit, attempt.id, %Secret{value: fun}}) end,
        attempt.fence
      )
    else
      _ -> {:error, :reconnect}
    end
  end

  defp current?(attempt) do
    attempt.expires > now() and valid_session?(attempt.session.value) and
      callback_url() == attempt.callback_url and
      case ClientCredentials.current() do
        {:ok, client} -> client.generation == attempt.client_generation
        _ -> false
      end
  end

  defp terminal(attempt, status), do: %{id: attempt.id, status: status, expires: now() + @ttl}
  defp public(nil), do: %{status: :idle}
  defp public(%{status: :cancelled}), do: %{status: :idle}

  defp public(%{status: status, id: id}) when status in [:queued, :exchanging],
    do: %{status: if(Lovelace.OAuth.pending?(id), do: :exchanging, else: :failed)}

  defp public(attempt), do: %{status: attempt.status}
  defp prune(attempts), do: Map.filter(attempts, fn {_, a} -> a.expires > now() end)
  defp find(attempts, id), do: Enum.find(attempts, fn {_, a} -> a.id == id end)
  defp valid_session?(session), do: match?({:ok, _}, Owner.verify_session(session))
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp now, do: System.monotonic_time(:millisecond)

  defp make_room(attempts, key) do
    if map_size(attempts) >= @limit and not Map.has_key?(attempts, key) do
      case Enum.find(attempts, fn {_, a} -> public(a).status not in [:pending, :exchanging] end) do
        {evict, _} -> Map.delete(attempts, evict)
        _ -> attempts
      end
    else
      attempts
    end
  end

  defp provider,
    do: Application.get_env(:lovelace, :github_provider, Lovelace.Integrations.GitHub)

  defp guarded_access(fun) do
    Vault.with_access(fun)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp call(message, fallback \\ {:error, :unavailable}) do
    GenServer.call(__MODULE__, message, 30_000)
  catch
    :exit, _ -> fallback
  end
end
