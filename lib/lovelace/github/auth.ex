defmodule Lovelace.GitHub.Auth do
  @moduledoc "Session-bound, single-use GitHub App web authorization, stopped by global Lock."
  use GenServer
  alias Lovelace.GitHub.{ClientCredentials, Operations}
  alias Lovelace.Owner
  alias Lovelace.Owner.Actions
  alias Lovelace.Security.{Secret, Vault}
  @service [actor: %{role: :owner_auth_service}]
  @limit 16
  @ttl 600_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def begin(session) when is_binary(session), do: call({:begin, %Secret{value: session}})
  def begin(_), do: {:error, :unavailable}

  def complete(session, params) when is_binary(session) and is_map(params),
    do: call({:complete, %Secret{value: {session, params}}}, {:error, :unavailable}, 180_000)

  def complete(_, _), do: {:error, :expired}
  def cancel(session) when is_binary(session), do: call({:cancel, Actions.digest(session)})
  def cancel(_), do: {:error, :unavailable}
  def status(digest) when is_binary(digest), do: call({:status, digest}, %{status: :idle})
  def status(_), do: %{status: :idle}

  def callback_url do
    uri = URI.parse(LovelaceWeb.Endpoint.url())

    if uri.scheme in ["http", "https"] and uri.host == "localhost" and
         uri.userinfo == nil and uri.query == nil and uri.fragment == nil do
      URI.to_string(%{uri | path: "/auth/github/callback"})
    else
      nil
    end
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:begin, %Secret{value: session}}, _from, attempts) do
    attempts = prune(attempts)
    key = Actions.digest(session)
    attempts = make_room(attempts, key)

    result = guarded_access(fn -> authorization_configuration(session) end)

    cond do
      match?(%{worker: worker} when is_pid(worker), attempts[key]) ->
        {:reply, {:error, :busy}, attempts}

      map_size(attempts) >= @limit and not Map.has_key?(attempts, key) ->
        {:reply, {:error, :busy}, attempts}

      true ->
        case result do
          {:ok, client, uri, fence} ->
            state = random()
            verifier = random()

            attempt = %{
              id: make_ref(),
              session: %Secret{value: session},
              state_digest: Actions.digest(state),
              verifier: %Secret{value: verifier},
              client_generation: client.generation,
              callback_url: uri,
              fence: fence,
              expires: now() + @ttl,
              status: :pending,
              worker: nil,
              caller: nil
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

  def handle_call({:complete, %Secret{value: {session, params}}}, from, attempts) do
    key = Actions.digest(session)

    case attempts[key] do
      %{status: :pending, expires: expires, state_digest: digest} = attempt ->
        if expires > now() and valid_session?(session) and
             is_binary(params["state"]) and Actions.digest(params["state"]) == digest do
          {:noreply, Map.put(attempts, key, launch_exchange(attempt, params, from))}
        else
          {:reply, {:error, :expired}, attempts}
        end

      _ ->
        {:reply, {:error, :expired}, attempts}
    end
  end

  def handle_call({:cancel, key}, _from, attempts) do
    case attempts[key] do
      %{status: :connected} -> {:reply, {:error, :already_authorized}, attempts}
      nil -> {:reply, :ok, attempts}
      attempt -> {:reply, :ok, Map.put(attempts, key, terminal(attempt, :cancelled))}
    end
  end

  def handle_call({:status, key}, _from, attempts) do
    attempts = prune(attempts)

    reply =
      if match?({:ok, _}, Owner.verify_digest(key, @service)),
        do: public(attempts[key]),
        else: %{status: :idle}

    {:reply, reply, attempts}
  end

  def handle_call({:commit, id, %Secret{value: fun}}, _from, attempts) do
    case find(attempts, id) do
      {key, %{status: :exchanging} = attempt} ->
        commit_attempt(attempt, key, fun, attempts)

      _ ->
        {:reply, {:error, :expired}, attempts}
    end
  end

  @impl true
  def handle_info({:completed, id, %Secret{value: result}}, attempts) do
    case find(attempts, id) do
      {key, %{status: :connected} = attempt} ->
        {:noreply, Map.put(attempts, key, %{attempt | worker: nil})}

      {key, attempt} ->
        result = if attempt.status == :exchanging, do: result, else: {:error, :expired}
        if attempt.caller, do: GenServer.reply(attempt.caller, result)
        status = if match?({:ok, _}, result), do: :connected, else: :failed
        settled = terminal(attempt, status) |> Map.merge(%{worker: nil, caller: nil})
        {:noreply, Map.put(attempts, key, settled)}

      _ ->
        {:noreply, attempts}
    end
  end

  def handle_info({:EXIT, pid, reason}, attempts) when reason != :normal do
    attempts = Map.new(attempts, fn {key, attempt} -> {key, worker_exited(attempt, pid)} end)

    {:noreply, attempts}
  end

  def handle_info(_, attempts), do: {:noreply, attempts}

  @impl true
  def terminate(_, attempts) do
    Enum.each(attempts, fn {_, attempt} ->
      if is_pid(attempt.worker), do: Process.exit(attempt.worker, :shutdown)
    end)
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

  defp launch_exchange(attempt, params, caller) do
    # Consume before spawning: crashes, concurrent callbacks and unknown exchange
    # outcomes can never retry the same authorization code.
    attempt = %{attempt | status: :exchanging, caller: caller}
    parent = self()
    worker = spawn_link(fn -> complete_exchange(attempt, params, parent) end)
    %{attempt | worker: worker}
  end

  defp complete_exchange(attempt, params, parent) do
    result = guarded_access(fn -> exchange(attempt, params, parent) end)
    send(parent, {:completed, attempt.id, %Secret{value: result}})
  end

  defp commit_attempt(attempt, key, fun, attempts) do
    result =
      if attempt.expires > now() and valid_session?(attempt.session.value),
        do: guarded_access(fun),
        else: {:error, :expired}

    {:reply, result, Map.put(attempts, key, committed_attempt(attempt, result))}
  end

  defp committed_attempt(attempt, {:ok, _} = result) do
    if attempt.caller, do: GenServer.reply(attempt.caller, result)
    terminal(attempt, :connected) |> Map.put(:caller, nil)
  end

  defp committed_attempt(attempt, _result), do: attempt

  defp worker_exited(attempt, pid) do
    cond do
      attempt.worker != pid ->
        attempt

      attempt.status == :connected ->
        %{attempt | worker: nil}

      true ->
        if attempt.caller, do: GenServer.reply(attempt.caller, {:error, :unavailable})
        terminal(attempt, :failed) |> Map.merge(%{worker: nil, caller: nil})
    end
  end

  defp exchange(attempt, params, parent) do
    with true <- is_nil(params["error"]),
         code when is_binary(code) and byte_size(code) in 1..4096 <- params["code"],
         true <- valid_session?(attempt.session.value),
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
        fn fun -> GenServer.call(parent, {:commit, attempt.id, %Secret{value: fun}}, 30_000) end,
        attempt.fence
      )
    else
      _ -> {:error, :reconnect}
    end
  end

  defp terminal(attempt, status),
    do:
      attempt
      |> Map.drop([:session, :verifier, :state_digest, :fence, :callback_url, :client_generation])
      |> Map.merge(%{status: status, expires: now() + @ttl})

  defp public(nil), do: %{status: :idle}
  defp public(%{status: :cancelled}), do: %{status: :idle}
  defp public(attempt), do: %{status: attempt.status}

  defp prune(attempts),
    do:
      Map.filter(attempts, fn {_, attempt} ->
        attempt.expires > now() or is_pid(attempt.worker)
      end)

  defp find(attempts, id), do: Enum.find(attempts, fn {_, attempt} -> attempt.id == id end)
  defp valid_session?(session), do: match?({:ok, _}, Owner.verify_session(session))
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp make_room(attempts, key) do
    if map_size(attempts) >= @limit and not Map.has_key?(attempts, key) do
      case Enum.find(attempts, fn {_, attempt} ->
             attempt.status not in [:pending, :exchanging] and not is_pid(attempt.worker)
           end) do
        {evict, _} -> Map.delete(attempts, evict)
        nil -> attempts
      end
    else
      attempts
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp provider,
    do: Application.get_env(:lovelace, :github_provider, Lovelace.Integrations.GitHub)

  defp guarded_access(fun), do: guarded(fn -> Vault.with_access(fun) end)

  defp guarded(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp call(message, fallback \\ {:error, :unavailable}, timeout \\ 30_000) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _ -> fallback
  end
end
