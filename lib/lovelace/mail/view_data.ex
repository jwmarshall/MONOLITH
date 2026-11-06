defmodule Lovelace.Mail.ViewData do
  @moduledoc "Ephemeral render payloads: LiveView telemetry sees opaque references, never message bodies."
  use GenServer
  alias Lovelace.Mail
  @limit 32 * 1024 * 1024
  @ttl 600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def put(data, owner \\ self(), scope \\ nil),
    do: GenServer.call(__MODULE__, {:put, owner, scope, data})

  def get(nil), do: nil
  def get(ref), do: GenServer.call(__MODULE__, {:get, ref})
  def clear(owner \\ self()), do: GenServer.call(__MODULE__, {:clear, owner})

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_call({:put, owner, scope, data}, _from, entries) do
    ref = make_ref()
    monitor = Process.monitor(owner)
    at = System.monotonic_time(:millisecond)
    timer = Process.send_after(self(), {:expire, ref}, at + @ttl, abs: true)

    entry = %{
      ref: ref,
      owner: owner,
      scope: scope,
      monitor: monitor,
      data: data,
      bytes: :erlang.external_size(data),
      at: at,
      timer: timer
    }

    retained = trim([entry | entries])
    {:reply, ref, retained}
  end

  def handle_call({:get, ref}, {caller, _}, entries) do
    now = System.monotonic_time(:millisecond)

    case Enum.find(entries, &(&1.ref == ref)) do
      %{at: at, data: data, owner: owner} = entry when now - at < @ttl ->
        if (owner == caller or entry.scope == nil) and authorized?(entry.scope),
          do: {:reply, data, entries},
          else: {:reply, nil, discard(entries, &(&1.ref == ref))}

      _ ->
        {:reply, nil, discard(entries, &(&1.ref == ref))}
    end
  end

  def handle_call({:clear, owner}, _from, entries) do
    {:reply, :ok, discard(entries, &(&1.owner == owner))}
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, entries),
    do: {:noreply, discard(entries, &(&1.owner == pid))}

  def handle_info({:expire, ref}, entries),
    do: {:noreply, discard(entries, &(&1.ref == ref))}

  @impl true
  def format_status(_), do: %{state: :redacted}

  defp authorized?(nil), do: true

  defp authorized?(scope) do
    actor = %{role: :local_owner}

    with {:ok, %{generation: generation, status: :ready}} <-
           Mail.get_account(scope.account_id, actor: actor),
         true <- generation == scope.generation do
      workspace_authorized?(scope, actor)
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp workspace_authorized?(%{workspace_id: nil}, _actor), do: true

  defp workspace_authorized?(scope, actor) do
    case Mail.workspace_accounts(scope.workspace_id, actor: actor) do
      {:ok, rows} -> Enum.any?(rows, &(&1.account_id == scope.account_id))
      _ -> false
    end
  end

  defp trim(entries) do
    now = System.monotonic_time(:millisecond)

    {keep, _bytes, _counts} =
      Enum.reduce(entries, {[], 0, %{}}, fn e, {keep, bytes, counts} = acc ->
        count = Map.get(counts, e.owner, 0)

        if bytes + e.bytes <= @limit && count < 4 && now - e.at < @ttl do
          {[e | keep], bytes + e.bytes, Map.put(counts, e.owner, count + 1)}
        else
          dispose(e)
          acc
        end
      end)

    Enum.reverse(keep)
  end

  defp discard(entries, predicate) do
    Enum.reject(entries, fn entry ->
      if predicate.(entry) do
        dispose(entry)
        true
      else
        false
      end
    end)
  end

  defp dispose(entry) do
    Process.cancel_timer(entry.timer)
    Process.demonitor(entry.monitor, [:flush])
  end
end
