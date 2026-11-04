defmodule Lovelace.Security.LeaseGuard do
  @moduledoc false
  use GenServer

  alias Lovelace.Security.Database

  @admission {Lovelace.Security.Vault, :admission}

  # Deliberately unlinked: a killed manager cannot run terminate/2, and linked
  # clients may trap exits. Keep the exclusion handle until their actual DOWNs.
  def start(owner, handle, keychain),
    do: GenServer.start(__MODULE__, {owner, handle, keychain}, name: __MODULE__)

  def await_previous do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> await_retirement(pid)
    end
  end

  def track(guard, token, pid), do: GenServer.call(guard, {:track, token, pid}, :infinity)
  def release(guard, token), do: GenServer.cast(guard, {:release, token})
  def protect(guard, pid), do: GenServer.call(guard, {:protect, pid}, :infinity)
  def retire(guard), do: GenServer.call(guard, :retire, :infinity)

  @impl true
  def init({owner, handle, keychain}) do
    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       handle: handle,
       keychain: keychain,
       leases: %{},
       monitors: %{},
       runtimes: %{},
       retiring?: false,
       waiters: []
     }}
  end

  @impl true
  def handle_call(:retiring?, _from, state),
    do: {:reply, state.retiring? or not Process.alive?(state.owner), state}

  def handle_call({:track, token, pid}, {owner, _}, %{owner: owner, retiring?: false} = state) do
    if Process.alive?(owner) do
      monitor = Process.monitor(pid)

      {:reply, :ok,
       %{
         state
         | leases: Map.put(state.leases, token, {pid, monitor}),
           monitors: Map.put(state.monitors, monitor, token)
       }}
    else
      {:reply, {:error, :locked}, state}
    end
  end

  def handle_call({:protect, pid}, _from, %{retiring?: false} = state) do
    if Process.alive?(state.owner) do
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | runtimes: Map.put(state.runtimes, ref, pid)}}
    else
      {:reply, {:error, :locked}, state}
    end
  end

  def handle_call(:retire, {owner, _} = from, %{owner: owner} = state) do
    state
    |> Map.put(:waiters, [from | state.waiters])
    |> retire_holders()
    |> settle()
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :locked}, state}

  @impl true
  def handle_cast({:release, token}, state) do
    case Map.pop(state.leases, token) do
      {nil, _} ->
        settle(state)

      {{_, monitor}, leases} ->
        Process.demonitor(monitor, [:flush])
        settle(%{state | leases: leases, monitors: Map.delete(state.monitors, monitor)})
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: state |> retire_holders() |> settle()

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {token, monitors} = Map.pop(state.monitors, ref)

    settle(%{
      state
      | leases: Map.delete(state.leases, token),
        monitors: monitors,
        runtimes: Map.delete(state.runtimes, ref)
    })
  end

  @impl true
  def format_status(_), do: %{state: :redacted, message: :redacted, reason: :redacted}

  defp retire_holders(state) do
    :persistent_term.put(@admission, false)
    Enum.each(state.leases, fn {_, {pid, _}} -> Process.exit(pid, :kill) end)
    %{state | retiring?: true}
  end

  defp settle(%{retiring?: true, leases: leases, runtimes: runtimes} = state)
       when map_size(leases) == 0 and map_size(runtimes) == 0 do
    result = state.keychain.lock()
    Database.release_runtime_lock(state.handle)
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    {:stop, :normal, state}
  end

  defp settle(state), do: {:noreply, state}

  defp await_retirement(pid) do
    ref = Process.monitor(pid)

    if GenServer.call(pid, :retiring?, :infinity) do
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      end
    else
      Process.demonitor(ref, [:flush])
      {:error, :vault_in_use}
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end
end
