defmodule Lovelace.Security.Vault do
  @moduledoc "Password-gated lifetime of the dedicated keychain, private database and background work."
  use GenServer

  alias Lovelace.Owner.Actions
  alias Lovelace.Security.{Database, Keychain, LeaseGuard, ProtectedSupervisor, Secret}

  @admission {__MODULE__, :admission}
  @startup {__MODULE__, :startup}
  @lifetime 12 * 60 * 60 * 1000

  def child_spec(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, shutdown: :infinity}
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  if Mix.env() == :test do
    def enabled?, do: Database.managed?()
    def open?, do: not enabled?() or admission() != false
  else
    def enabled?, do: true
    def open?, do: admission() != false
  end

  def configuration_status do
    database = Application.fetch_env!(:lovelace, Lovelace.Repo)[:database]

    cond do
      Keychain.setup_pending?() ->
        :setup_incomplete

      Database.migration_pending?() ->
        :migration_required

      true ->
        case {keychain().configured?(), File.regular?(database)} do
          {true, true} -> :configured
          {true, false} -> :unavailable
          {false, true} -> :migration_required
          {false, false} -> :new
        end
    end
  end

  if Mix.env() == :test do
    def unlock(password, authenticate, options \\ []) when is_function(authenticate, 0) do
      if enabled?(),
        do: call({:unlock, %Secret{value: password}, authenticate, options}),
        else: authenticate.()
    end

    def lock do
      if enabled?(), do: call(:lock), else: Actions.revoke_sessions()
    end

    def with_access(fun) when is_function(fun, 0) do
      if enabled?(), do: leased(fun, admission()), else: fun.()
    end

    def track, do: if(enabled?(), do: acquire_access(), else: {:ok, nil})
  else
    def unlock(password, authenticate, options \\ []) when is_function(authenticate, 0),
      do: call({:unlock, %Secret{value: password}, authenticate, options})

    def lock, do: call(:lock)
    def with_access(fun) when is_function(fun, 0), do: leased(fun, admission())
    def track, do: acquire_access()
  end

  @doc false
  def with_keychain_access(fun) when is_function(fun, 0) do
    epoch = admission()
    result = fun.()

    if epoch != false and keychain_access_failed?(result) do
      if Process.whereis(__MODULE__) == self() do
        close_admission()
        send(self(), {:keychain_failure, epoch})
      else
        call({:keychain_failure, epoch})
      end
    end

    result
  end

  def setup(password, configure) when is_function(configure, 0),
    do: call({:setup, %Secret{value: password}, configure})

  def release(nil), do: :ok
  def release(ref), do: GenServer.cast(__MODULE__, {:release, ref})

  def start_maintenance do
    with nil <- Process.whereis(Lovelace.Supervisor),
         {:ok, _} <- Application.ensure_all_started(:ash_sqlite),
         {:ok, _} <- Application.ensure_all_started(:ash_authentication),
         {:ok, _} <- Application.ensure_all_started(:phoenix_pubsub) do
      Supervisor.start_link(
        [
          {Phoenix.PubSub, name: Lovelace.PubSub},
          Lovelace.Owner.Throttle,
          {__MODULE__, []}
        ],
        strategy: :one_for_all
      )
    else
      _ -> {:error, :maintenance_unavailable}
    end
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    close_admission()

    with :ok <- LeaseGuard.await_previous(),
         {:ok, handle} <- Database.acquire_runtime_lock(),
         {:ok, guard} <- start_guard(handle) do
      {:ok,
       %{
         handle: handle,
         guard: guard,
         runtime: nil,
         mode: :locked,
         epoch: nil,
         leases: %{},
         timer: nil,
         startup_id: Keyword.get(options, :startup_id)
       }}
    else
      _ -> {:stop, :vault_unavailable}
    end
  end

  @impl true
  def handle_call({:unlock, %Secret{value: password}, authenticate, options}, _from, state) do
    {result, state} = open(password, authenticate, options, state)
    {:reply, result, state}
  end

  def handle_call({:setup, %Secret{value: password}, configure}, _from, %{runtime: nil} = state) do
    result =
      if keychain().configured?() and not Keychain.initializing?(),
        do: :ok,
        else: keychain().create(password)

    case result do
      :ok ->
        {result, state} = open(password, configure, [maintenance: true, setup: true], state)
        {:reply, result, state}

      _ ->
        {:reply, {:error, :setup_unavailable}, state}
    end
  end

  def handle_call({:setup, _, _}, _from, state),
    do: {:reply, {:error, :already_open}, state}

  def handle_call(:lock, {caller, _}, state) do
    {result, state} = close(state, caller)
    {:reply, result, state}
  end

  def handle_call({:keychain_failure, epoch}, from, %{epoch: epoch} = state)
      when not is_nil(epoch) do
    close_admission()
    # The reporter may be a protected worker: release its call before draining
    # leases and stopping its supervisor, without admitting any new work.
    GenServer.reply(from, :ok)
    {_result, state} = close(state, nil)
    {:noreply, state}
  end

  def handle_call({:keychain_failure, _}, _from, state), do: {:reply, :ok, state}

  def handle_call({:acquire, epoch}, {pid, _}, %{epoch: epoch, mode: mode} = state)
      when not is_nil(epoch) and mode in [:open, :maintenance] do
    ref = Process.monitor(pid)

    case LeaseGuard.track(state.guard, ref, pid) do
      :ok ->
        {:reply, {:ok, ref}, %{state | leases: Map.put(state.leases, ref, pid)}}

      _ ->
        Process.demonitor(ref, [:flush])
        {:reply, {:error, :locked}, state}
    end
  end

  def handle_call({:acquire, _}, _from, state), do: {:reply, {:error, :locked}, state}

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    LeaseGuard.release(state.guard, ref)
    {:noreply, %{state | leases: Map.delete(state.leases, ref)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    state = %{state | leases: Map.delete(state.leases, ref)}

    if state.mode == :locked and map_size(state.leases) == 0 and state.runtime do
      {_result, state} = finish_close(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:ready, epoch, startup?}, %{epoch: epoch, mode: :open} = state) do
    case ProtectedSupervisor.resume(state.runtime, startup?) do
      :ok ->
        {:noreply, state}

      _ ->
        {_result, state} = close(state, nil)
        {:noreply, state}
    end
  end

  def handle_info({:ready, _, _}, state), do: {:noreply, state}

  def handle_info({:keychain_failure, epoch}, %{epoch: epoch} = state)
      when not is_nil(epoch) do
    {_result, state} = close(state, nil)
    {:noreply, state}
  end

  def handle_info({:keychain_failure, _}, state), do: {:noreply, state}

  def handle_info({:expire, generation}, %{timer: {_, generation}} = state) do
    {_result, state} = close(state, nil)
    {:noreply, state}
  end

  def handle_info({:expire, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _}, %{runtime: pid} = state) when not is_nil(pid) do
    {_result, state} = close(%{state | runtime: nil}, nil)
    {:noreply, state}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    close_admission()
    cancel_timer(state.timer)
    drain(state.leases, nil, state.guard, :infinity)
    stop_runtime(state.runtime)
    LeaseGuard.retire(state.guard)
  end

  @impl true
  def format_status(_), do: %{state: :redacted, message: :redacted, reason: :redacted}

  defp open(_password, _authenticate, _options, %{leases: leases} = state)
       when map_size(leases) > 0 and state.mode == :locked,
       do: {{:error, :lock_pending}, state}

  defp open(password, authenticate, options, state) do
    case prepare(password, options, state) do
      {:ok, prepared} -> authenticate(authenticate, options, state, prepared)
      _ -> {{:error, :unlock_unavailable}, reset_failed_open(state)}
    end
  end

  defp prepare(password, _options, %{runtime: runtime} = state) when not is_nil(runtime) do
    with :ok <- keychain().unlock(password), do: {:ok, state}
  end

  defp prepare(password, options, state) do
    with true <- Keyword.get(options, :setup, false) or configuration_status() == :configured,
         :ok <- keychain().unlock(password),
         {:ok, key} <- keychain().database_key(),
         {:ok, runtime} <- ProtectedSupervisor.start_link(key, state.handle, state.guard) do
      prepared = %{state | runtime: runtime}

      case initialize_database() do
        :ok ->
          {:ok, prepared}

        _ ->
          stop_runtime(runtime)
          {:error, :database_unavailable}
      end
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp initialize_database do
    with :ok <- Database.validate(),
         :ok <- Database.migrate(),
         {:ok, true} <- Actions.revoke_sessions(),
         do: :ok
  end

  defp authenticate(fun, options, original, prepared) do
    case safe_authenticate(fun) do
      {:ok, _} = result ->
        case activate(prepared, options) do
          {:ok, opened} -> {result, schedule_expiry(opened)}
          _ -> {{:error, :unlock_unavailable}, reset_failed_open(prepared)}
        end

      _ ->
        {{:error, :invalid_password}, rollback(original, prepared)}
    end
  end

  defp safe_authenticate(fun) do
    fun.()
  rescue
    _ -> {:error, :authentication_unavailable}
  catch
    _, _ -> {:error, :authentication_unavailable}
  end

  defp activate(%{mode: :open} = state, _), do: {:ok, state}

  defp activate(state, options) do
    maintenance? = Keyword.get(options, :maintenance, false)
    startup? = not maintenance? and startup_pending?(state.startup_id)

    if not maintenance?, do: remember_startup(state.startup_id)

    result = if maintenance?, do: :ok, else: ProtectedSupervisor.activate(state.runtime)

    with :ok <- result do
      epoch = state.epoch || make_ref()
      :persistent_term.put(@admission, epoch)
      if not maintenance?, do: send(self(), {:ready, epoch, startup?})
      {:ok, %{state | mode: if(maintenance?, do: :maintenance, else: :open), epoch: epoch}}
    end
  end

  defp rollback(%{runtime: nil}, prepared), do: reset_failed_open(prepared)
  defp rollback(original, _), do: original

  defp reset_failed_open(%{mode: :locked} = state) do
    stop_runtime(state.runtime)
    keychain().lock()
    %{state | runtime: nil}
  end

  defp reset_failed_open(state) do
    {_result, state} = close(state, nil)
    state
  end

  defp close(state, caller) do
    close_admission()
    cancel_timer(state.timer)
    remaining = drain(state.leases, caller, state.guard, 5_000)
    state = %{state | mode: :locked, epoch: nil, leases: remaining, timer: nil}

    if map_size(remaining) == 0,
      do: finish_close(state),
      else: {{:error, :lock_pending}, state}
  end

  defp finish_close(state) do
    revoke_result =
      if state.runtime, do: Actions.revoke_sessions(), else: {:ok, true}

    stop_runtime(state.runtime)
    lock_result = keychain().lock()

    result =
      if revoke_result == {:ok, true} and lock_result == :ok,
        do: {:ok, true},
        else: {:error, :lock_unavailable}

    {result, %{state | runtime: nil}}
  end

  defp drain(leases, caller, guard, timeout) do
    remaining =
      Enum.reduce(leases, %{}, fn {ref, pid}, pending ->
        if pid == caller do
          Process.demonitor(ref, [:flush])
          LeaseGuard.release(guard, ref)
          pending
        else
          Process.exit(pid, :kill)
          Map.put(pending, ref, pid)
        end
      end)

    deadline =
      if timeout == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + timeout

    await_drained(remaining, deadline)
  end

  defp await_drained(leases, _) when map_size(leases) == 0, do: leases

  defp await_drained(leases, deadline) do
    timeout =
      if deadline == :infinity,
        do: :infinity,
        else: max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ref, :process, _, _} when is_map_key(leases, ref) ->
        await_drained(Map.delete(leases, ref), deadline)
    after
      timeout -> leases
    end
  end

  defp stop_runtime(nil), do: :ok

  defp stop_runtime(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :shutdown, :infinity)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp schedule_expiry(state) do
    cancel_timer(state.timer)
    generation = make_ref()
    timer = Process.send_after(self(), {:expire, generation}, @lifetime)
    %{state | timer: {timer, generation}}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _}), do: Process.cancel_timer(timer)

  defp acquire_access do
    case admission() do
      false -> {:error, :locked}
      epoch -> call({:acquire, epoch})
    end
  end

  defp leased(_fun, false), do: {:error, :locked}

  defp leased(fun, epoch) do
    case call({:acquire, epoch}) do
      {:ok, ref} ->
        try do
          fun.()
        after
          release(ref)
        end

      _ ->
        {:error, :locked}
    end
  end

  defp call(message) do
    GenServer.call(__MODULE__, message, :infinity)
  catch
    :exit, _ -> {:error, :vault_unavailable}
  end

  defp start_guard(handle) do
    with :ok <- keychain().lock(),
         {:ok, guard} <- LeaseGuard.start(self(), handle, keychain()) do
      {:ok, guard}
    else
      _ ->
        Database.release_runtime_lock(handle)
        {:error, :vault_unavailable}
    end
  end

  if Mix.env() == :test do
    defp keychain, do: Application.get_env(:lovelace, :vault_keychain, Keychain)
  else
    defp keychain, do: Keychain
  end

  defp keychain_access_failed?({:error, reason}),
    do: reason in [:locked, :missing, :unavailable, :timeout, :invalid_directory]

  defp keychain_access_failed?({:ok, status}), do: status in [:locked, :missing]
  defp keychain_access_failed?(_), do: false

  defp admission, do: :persistent_term.get(@admission, false)
  defp close_admission, do: :persistent_term.put(@admission, false)
  defp startup_pending?(nil), do: false
  defp startup_pending?(id), do: :persistent_term.get(@startup, nil) != id
  defp remember_startup(nil), do: :ok
  defp remember_startup(id), do: :persistent_term.put(@startup, id)
end
