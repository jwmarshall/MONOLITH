defmodule Lovelace.GitHub.Auth do
  @moduledoc "Session-bound, ephemeral GitHub App device authorization, stopped by global Lock."
  use GenServer
  alias Lovelace.GitHub.Operations
  alias Lovelace.Owner
  alias Lovelace.Owner.Actions
  alias Lovelace.Security.{Secret, Vault}
  @service [actor: %{role: :owner_auth_service}]
  @limit 16

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def begin(session) when is_binary(session), do: call({:begin, %Secret{value: session}})
  def begin(_), do: {:error, :unavailable}
  def cancel(session) when is_binary(session), do: call({:cancel, Actions.digest(session)})
  def cancel(_), do: {:error, :unavailable}
  def status(digest) when is_binary(digest), do: call({:status, digest}, %{status: :idle})
  def status(_), do: %{status: :idle}

  def configured? do
    config = Application.get_env(:lovelace, :github, [])
    valid_client?(config[:client_id]) && valid_slug?(config[:app_slug])
  end

  def installation_url do
    if configured?(),
      do: "https://github.com/apps/" <> config(:app_slug) <> "/installations/new"
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

    cond do
      not configured?() ->
        {:reply, {:error, :configuration}, attempts}

      not valid_session?(session) ->
        {:reply, {:error, :unavailable}, attempts}

      active?(attempts[key]) ->
        {:reply, :ok, attempts}

      match?(%{worker: worker} when is_pid(worker), attempts[key]) ->
        {:reply, {:error, :busy}, attempts}

      map_size(attempts) >= @limit && not Map.has_key?(attempts, key) ->
        {:reply, {:error, :busy}, attempts}

      true ->
        id = make_ref()

        attempt = %{
          id: id,
          session: %Secret{value: session},
          status: :starting,
          expires: now() + 900_000,
          client_id: config(:client_id),
          fence: Operations.authorization_fence(),
          worker: nil
        }

        attempt = launch(attempt, fn -> provider().device_code(attempt.client_id) end, :device)
        {:reply, :ok, Map.put(attempts, key, attempt)}
    end
  end

  def handle_call({:cancel, key}, _from, attempts) do
    case attempts[key] do
      %{status: :connected} ->
        {:reply, {:error, :already_authorized}, attempts}

      nil ->
        {:reply, :ok, attempts}

      attempt ->
        # Retain the worker slot: cancel/restart cannot bypass concurrency bounds.
        cancelled = attempt |> terminal(:cancelled) |> Map.put(:worker, attempt.worker)
        {:reply, :ok, Map.put(attempts, key, cancelled)}
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
      {key, %{status: :pending, session: %Secret{value: session}, expires: expires} = attempt} ->
        result = commit_if_current(session, expires, fun)

        settled = poll_result(attempt, result) |> Map.put(:worker, attempt.worker)
        {:reply, result, Map.put(attempts, key, settled)}

      _ ->
        {:reply, {:error, :expired}, attempts}
    end
  end

  @impl true
  def handle_info({:device, id, %Secret{value: result}}, attempts) do
    {:noreply, update_result(attempts, id, result)}
  end

  def handle_info({:poll, id}, attempts) do
    case find(attempts, id) do
      {key, %{status: :pending, worker: nil} = attempt} ->
        {:noreply, Map.put(attempts, key, launch_poll(attempt))}

      _ ->
        {:noreply, attempts}
    end
  end

  def handle_info({:polled, id, %Secret{value: result}}, attempts) do
    {:noreply, update_poll(attempts, id, result)}
  end

  def handle_info({:EXIT, pid, reason}, attempts) do
    attempts =
      Map.new(attempts, fn {key, attempt} ->
        if attempt.worker == pid and reason != :normal,
          do: {key, failed(attempt, :unavailable)},
          else: {key, attempt}
      end)

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
  def format_status(_), do: %{state: :redacted}

  defp commit_if_current(session, expires, fun) do
    if expires > now() and valid_session?(session),
      do: guarded(fn -> Vault.with_access(fun) end),
      else: {:error, :expired}
  end

  defp launch_poll(attempt) do
    if attempt.expires > now() and valid_session?(attempt.session.value) do
      parent = self()
      launch(attempt, fn -> poll(attempt, parent) end, :polled)
    else
      failed(attempt, :expired)
    end
  end

  defp poll(attempt, parent) do
    case provider().exchange_device(attempt.client_id, attempt.device_code.value) do
      {:ok, bundle} ->
        Operations.authorize(
          attempt.session.value,
          bundle,
          fn fun ->
            GenServer.call(parent, {:commit, attempt.id, %Secret{value: fun}}, 30_000)
          end,
          attempt.fence
        )

      other ->
        other
    end
  end

  defp launch(attempt, fun, event) do
    parent = self()

    worker =
      spawn_link(fn ->
        result = guarded(fn -> Vault.with_access(fun) end)
        send(parent, {event, attempt.id, %Secret{value: result}})
      end)

    %{attempt | worker: worker}
  end

  defp update_result(attempts, id, result) do
    case find(attempts, id) do
      {key, %{status: :starting} = attempt} ->
        Map.put(attempts, key, device_result(attempt, result))

      {key, attempt} ->
        Map.put(attempts, key, %{attempt | worker: nil})

      _ ->
        attempts
    end
  end

  defp device_result(attempt, {:ok, code}) do
    if valid_code?(code) do
      interval = max(code.interval, 5)
      Process.send_after(self(), {:poll, attempt.id}, interval * 1000)

      attempt
      |> Map.merge(%{
        status: :pending,
        device_code: %Secret{value: code.device_code},
        user_code: code.user_code,
        interval: interval,
        expires: now() + min(code.expires_in, 900) * 1000,
        worker: nil
      })
    else
      failed(attempt, :provider)
    end
  end

  defp device_result(attempt, {:error, reason}), do: failed(attempt, reason)
  defp device_result(attempt, _), do: failed(attempt, :provider)

  defp update_poll(attempts, id, result) do
    case find(attempts, id) do
      {key, %{status: :pending} = attempt} -> Map.put(attempts, key, poll_result(attempt, result))
      {key, attempt} -> Map.put(attempts, key, %{attempt | worker: nil})
      _ -> attempts
    end
  end

  defp poll_result(attempt, {:error, :authorization_pending}),
    do: schedule(attempt, attempt.interval)

  defp poll_result(attempt, {:slow_down, seconds}) when is_integer(seconds) and seconds > 0,
    do: schedule(attempt, max(attempt.interval + 5, seconds))

  defp poll_result(attempt, {:ok, _}),
    do: terminal(attempt, :connected)

  defp poll_result(attempt, {:error, reason}), do: failed(attempt, reason)
  defp poll_result(attempt, _), do: failed(attempt, :provider)

  defp schedule(attempt, interval) do
    Process.send_after(self(), {:poll, attempt.id}, min(interval, 900) * 1000)
    %{attempt | interval: interval, worker: nil}
  end

  defp failed(attempt, reason),
    do: attempt |> terminal(:failed) |> Map.put(:error, safe_error(reason))

  defp find(attempts, id), do: Enum.find(attempts, fn {_, attempt} -> attempt.id == id end)
  defp active?(%{status: status}), do: status in [:starting, :pending]
  defp active?(_), do: false
  defp public(nil), do: %{status: :idle}
  defp public(%{status: :cancelled}), do: %{status: :idle}
  defp public(attempt), do: Map.take(attempt, [:status, :user_code, :error])

  defp terminal(attempt, status),
    do:
      attempt
      |> Map.drop([:device_code, :user_code, :session, :fence])
      |> Map.merge(%{status: status, worker: nil, expires: now() + 300_000})

  defp prune(attempts) do
    Map.new(attempts, fn {key, attempt} ->
      if active?(attempt) and attempt.expires <= now(),
        do: {key, failed(attempt, :expired) |> Map.put(:worker, attempt.worker)},
        else: {key, attempt}
    end)
    |> Map.filter(fn {_, attempt} -> attempt.expires > now() or is_pid(attempt.worker) end)
  end

  defp valid_code?(%{device_code: device, user_code: user, expires_in: ttl, interval: interval}),
    do:
      is_binary(device) and byte_size(device) in 1..1024 and is_binary(user) and
        Regex.match?(~r/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/, user) and is_integer(ttl) and
        ttl in 1..900 and is_integer(interval) and interval in 1..900

  defp valid_code?(_), do: false

  defp valid_client?(id), do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_.-]{1,128}\z/, id)

  defp valid_slug?(slug),
    do: is_binary(slug) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,99}\z/, slug)

  defp valid_session?(session), do: match?({:ok, _}, Owner.verify_session(session))
  defp config(key), do: Keyword.get(Application.get_env(:lovelace, :github, []), key)

  defp provider,
    do: Application.get_env(:lovelace, :github_provider, Lovelace.Integrations.GitHub)

  defp now, do: System.monotonic_time(:millisecond)

  defp guarded(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp safe_error(reason)
       when reason in [
              :configuration,
              :denied,
              :expired,
              :keychain,
              :reconnect,
              :rate_limited,
              :provider,
              :unavailable
            ],
       do: reason

  defp safe_error(_), do: :provider

  defp call(message, fallback \\ {:error, :unavailable}) do
    GenServer.call(__MODULE__, message, 30_000)
  catch
    :exit, _ -> fallback
  end
end
