defmodule Lovelace.Owner.ThrottleTest do
  use ExUnit.Case, async: true
  alias Lovelace.Owner.Throttle

  setup do
    name = {:global, make_ref()}
    start_supervised!({Throttle, name: name})
    %{server: name}
  end

  test "limits each client without trusting forwarded headers", %{server: server} do
    for _ <- 1..5, do: assert(Throttle.allow?("127.0.0.1", server))
    refute Throttle.allow?("127.0.0.1", server)
    assert Throttle.allow?("127.0.0.2", server)
  end

  test "a global budget bounds clients and hashing work", %{server: server} do
    for n <- 1..30, do: assert(Throttle.allow?("client-#{n}", server))
    refute Throttle.allow?("new-client", server)
    state = :sys.get_state(server)
    assert map_size(state.clients) == 30
    refute Map.has_key?(state.clients, "client-1")
  end

  test "expired windows reset using monotonic time", %{server: server} do
    for _ <- 1..5, do: assert(Throttle.allow?("client", server))

    :sys.replace_state(server, fn state ->
      past = System.monotonic_time(:millisecond) - 1

      %{
        state
        | global: {30, past},
          clients: Map.new(state.clients, fn {key, _} -> {key, {5, past}} end)
      }
    end)

    assert Throttle.allow?("client", server)
  end

  test "missing throttle fails closed" do
    refute Throttle.allow?("client", {:global, make_ref()})
  end
end
