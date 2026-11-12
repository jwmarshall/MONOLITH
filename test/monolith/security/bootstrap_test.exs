defmodule Monolith.Security.BootstrapTest do
  use ExUnit.Case, async: true
  alias Monolith.Security.{Bootstrap, Secret}

  setup do
    observer = self()
    clock = start_supervised!({Agent, fn -> 1_000 end})
    state = start_supervised!(%{id: :setup_status, start: {Agent, :start_link, [fn -> :new end]}})

    server =
      start_supervised!(%{
        id: Bootstrap,
        start:
          {GenServer, :start_link,
           [
             Bootstrap,
             [
               announce: fn code -> send(observer, {:pairing_code, code}) end,
               clock: fn -> Agent.get(clock, & &1) end,
               status: fn -> Agent.get(state, & &1) end,
               configure: fn _password ->
                 send(observer, :owner_created)
                 Agent.update(state, fn _ -> :configured end)
                 {:ok, "synthetic-owner-session"}
               end
             ]
           ]}
      })

    assert_receive {:pairing_code, code}
    %{server: server, code: code, clock: clock, state: state}
  end

  test "only one browser can redeem the terminal code", %{server: server, code: code} do
    assert {:error, :pairing} = GenServer.call(server, {:pair, String.duplicate("x", 43)})

    results =
      1..2
      |> Task.async_stream(fn _ -> GenServer.call(server, {:pair, code}) end)
      |> Enum.map(fn {:ok, value} -> value end)

    assert [{:error, :pairing}, {:ok, _}] = Enum.sort(results)
    assert {:error, :pairing} = GenServer.call(server, {:pair, code})
  end

  test "password setup requires the paired browser and explicit recovery acknowledgement", %{
    server: server,
    code: code
  } do
    assert {:error, :setup} = configure(server, "unpaired")
    refute_receive :owner_created
    assert {:ok, capability} = GenServer.call(server, {:pair, code})
    assert {:error, :acknowledgement} = configure(server, capability, false)
    refute_receive :owner_created
    assert {:ok, "synthetic-owner-session"} = configure(server, capability)
    assert_receive :owner_created
    assert {:error, :setup} = configure(server, capability)
    refute_receive :owner_created
  end

  test "expired pairing cannot create an owner or be redeemed again", %{
    server: server,
    code: code,
    clock: clock
  } do
    assert {:ok, capability} = GenServer.call(server, {:pair, code})
    Agent.update(clock, &(&1 + 15 * 60 * 1000))
    assert false == GenServer.call(server, {:paired, capability})
    assert {:error, :setup} = configure(server, capability)
    assert {:error, :pairing} = GenServer.call(server, {:pair, code})
    refute_receive :owner_created
  end

  test "changed storage fences a previously paired browser", %{
    server: server,
    code: code,
    state: state
  } do
    assert {:ok, capability} = GenServer.call(server, {:pair, code})
    Agent.update(state, fn _ -> :migration_required end)
    assert {:error, :setup} = configure(server, capability)
    refute_receive :owner_created
  end

  test "password validation leaves pairing usable without creating storage", %{
    server: server,
    code: code
  } do
    assert {:ok, capability} = GenServer.call(server, {:pair, code})

    assert {:error, :password} =
             GenServer.call(
               server,
               {:configure, capability, %Secret{value: "short"}, %Secret{value: "short"}, true}
             )

    assert {:error, :confirmation} =
             GenServer.call(
               server,
               {:configure, capability, %Secret{value: "long synthetic password"},
                %Secret{value: "different password"}, true}
             )

    refute_receive :owner_created
    assert {:ok, "synthetic-owner-session"} = configure(server, capability)
  end

  defp configure(server, capability, acknowledged? \\ true) do
    password = %Secret{value: "synthetic onboarding password"}
    GenServer.call(server, {:configure, capability, password, password, acknowledged?})
  end
end
