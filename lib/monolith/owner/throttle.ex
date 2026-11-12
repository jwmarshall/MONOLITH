defmodule Monolith.Owner.Throttle do
  @moduledoc "Bounded node-local login budget: 5 attempts/client/minute, 30 total/minute."
  use GenServer
  @window 60_000
  @client_limit 5
  @global_limit 30
  @max_clients 1024

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  def allow?(client, server \\ __MODULE__) when is_binary(client) do
    GenServer.call(server, {:take, :crypto.hash(:sha256, client)})
  catch
    :exit, _ -> false
  end

  @impl true
  def init(_), do: {:ok, %{clients: %{}, global: {0, 0}}}

  @impl true
  def handle_call({:take, client}, _from, state) do
    now = System.monotonic_time(:millisecond)
    clients = Map.reject(state.clients, fn {_key, {_count, expiry}} -> expiry <= now end)
    {total, global_expiry} = current(state.global, now)
    {count, expiry} = current(Map.get(clients, client, {0, 0}), now)

    allowed =
      total < @global_limit and count < @client_limit and
        (Map.has_key?(clients, client) or map_size(clients) < @max_clients)

    if allowed do
      clients = Map.put(clients, client, {count + 1, expiry})
      {:reply, true, %{clients: clients, global: {total + 1, global_expiry}}}
    else
      {:reply, false, %{state | clients: clients}}
    end
  end

  defp current({0, 0}, now), do: {0, now + @window}
  defp current({count, expiry}, now) when expiry > now, do: {count, expiry}
  defp current(_, now), do: {0, now + @window}
end
