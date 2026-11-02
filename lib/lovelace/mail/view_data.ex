defmodule Lovelace.Mail.ViewData do
  @moduledoc "Ephemeral render payloads: LiveView telemetry sees opaque references, never message bodies."
  use GenServer
  @limit 32 * 1024 * 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def put(data, owner \\ self()), do: GenServer.call(__MODULE__, {:put, owner, data})
  def get(nil), do: nil
  def get(ref), do: GenServer.call(__MODULE__, {:get, ref})
  def clear(owner \\ self()), do: GenServer.call(__MODULE__, {:clear, owner})

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_call({:put, owner, data}, _from, entries) do
    ref = make_ref()
    monitor = Process.monitor(owner)

    entry = %{
      ref: ref,
      owner: owner,
      monitor: monitor,
      data: data,
      bytes: :erlang.external_size(data),
      at: System.monotonic_time(:millisecond)
    }

    retained = trim([entry | entries])
    {:reply, ref, retained}
  end

  def handle_call({:get, ref}, _from, entries) do
    now = System.monotonic_time(:millisecond)

    case Enum.find(entries, &(&1.ref == ref)) do
      %{at: at, data: data} when now - at < 600_000 -> {:reply, data, entries}
      _ -> {:reply, nil, discard(entries, &(&1.ref == ref))}
    end
  end

  def handle_call({:clear, owner}, _from, entries) do
    {:reply, :ok, discard(entries, &(&1.owner == owner))}
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, entries),
    do: {:noreply, discard(entries, &(&1.owner == pid))}

  @impl true
  def format_status(_), do: %{state: :redacted}

  defp trim(entries) do
    now = System.monotonic_time(:millisecond)

    {keep, _bytes, _counts} =
      Enum.reduce(entries, {[], 0, %{}}, fn e, {keep, bytes, counts} = acc ->
        count = Map.get(counts, e.owner, 0)

        if bytes + e.bytes <= @limit && count < 4 && now - e.at < 600_000 do
          {[e | keep], bytes + e.bytes, Map.put(counts, e.owner, count + 1)}
        else
          Process.demonitor(e.monitor, [:flush])
          acc
        end
      end)

    Enum.reverse(keep)
  end

  defp discard(entries, predicate) do
    Enum.reject(entries, fn entry ->
      if predicate.(entry) do
        Process.demonitor(entry.monitor, [:flush])
        true
      else
        false
      end
    end)
  end
end
