defmodule Monolith.Mail.RequestOwners do
  @moduledoc "Bounded ephemeral view ownership only; no provider work or durable scheduling."
  use GenServer
  @limit 128
  @ttl 600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def register(id, owner), do: GenServer.call(__MODULE__, {:register, id, owner})
  def owner(id), do: GenServer.call(__MODULE__, {:owner, id})
  def result(id), do: GenServer.call(__MODULE__, {:result, id})
  def stage(id, result), do: GenServer.call(__MODULE__, {:stage, id, result})
  def publish(id), do: GenServer.call(__MODULE__, {:publish, id})
  def commit(id), do: GenServer.call(__MODULE__, {:commit, id})
  def rollback(id), do: GenServer.call(__MODULE__, {:rollback, id})
  def release(owner \\ self()), do: GenServer.call(__MODULE__, {:release, owner})

  @impl true
  def init(_), do: {:ok, %{}}
  @impl true
  def handle_call({:register, id, owner}, _from, entries) do
    entries = live(entries)
    previous = Enum.find(entries, fn {_, e} -> e.owner == owner end)
    entries = discard(entries, fn e -> e.owner == owner end)

    if map_size(entries) < @limit and is_pid(owner) and Process.alive?(owner) do
      entry = %{
        owner: owner,
        monitor: Process.monitor(owner),
        at: now(),
        result: nil,
        previous: previous
      }

      {:reply, {:ok, if(previous, do: elem(previous, 0))}, Map.put(entries, id, entry)}
    else
      {:reply, {:error, :busy}, entries}
    end
  end

  def handle_call({:commit, id}, {caller, _}, entries) do
    case entries[id] do
      %{owner: ^caller} ->
        {:reply, :ok, put_in(entries, [id, :previous], nil)}

      _ ->
        {:reply, :expired, entries}
    end
  end

  def handle_call({:rollback, id}, {caller, _}, entries) do
    case entries[id] do
      %{owner: ^caller} = entry ->
        Process.demonitor(entry.monitor, [:flush])
        retained = restore_previous(Map.delete(entries, id), entry.previous)
        {:reply, :ok, live(retained)}

      _ ->
        {:reply, :expired, entries}
    end
  end

  def handle_call({:owner, id}, _from, entries) do
    entries = live(entries)

    {:reply,
     case entries[id] do
       nil -> nil
       entry -> entry.owner
     end, entries}
  end

  def handle_call({:result, id}, {caller, _}, entries) do
    entries = live(entries)

    result =
      case entries[id] do
        %{owner: ^caller, result: result} -> result
        _ -> nil
      end

    {:reply, result, entries}
  end

  def handle_call({:stage, id, result}, _from, entries) do
    entries = live(entries)

    case entries[id] do
      nil ->
        {:reply, :expired, entries}

      _ ->
        {:reply, :ok, put_in(entries, [id, :result], result)}
    end
  end

  def handle_call({:publish, id}, _from, entries) do
    entries = live(entries)

    case entries[id] do
      %{result: result} = entry when not is_nil(result) ->
        send(entry.owner, {:mail_operation, id})
        {:reply, :ok, entries}

      _ ->
        {:reply, :expired, entries}
    end
  end

  def handle_call({:release, owner}, _from, entries),
    do: {:reply, :ok, discard(entries, &(&1.owner == owner))}

  @impl true
  def handle_info({:DOWN, _, :process, owner, _}, entries),
    do: {:noreply, discard(entries, &(&1.owner == owner))}

  @impl true
  def format_status(_), do: %{state: :redacted}

  defp live(entries) do
    now = now()
    discard(entries, &(now - &1.at >= @ttl or not Process.alive?(&1.owner)))
  end

  defp restore_previous(entries, nil), do: entries

  defp restore_previous(entries, {id, entry}),
    do: Map.put(entries, id, %{entry | monitor: Process.monitor(entry.owner)})

  defp discard(entries, predicate) do
    Map.reject(entries, fn {_, entry} ->
      if predicate.(entry) do
        Process.demonitor(entry.monitor, [:flush])
        true
      else
        false
      end
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
