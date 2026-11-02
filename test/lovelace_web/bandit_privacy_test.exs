defmodule LovelaceWeb.BanditPrivacyTest do
  use ExUnit.Case, async: false

  test "stock Bandit retains documented in-process conn metadata before the endpoint" do
    # This is an explicitly accepted local-only exception, not an assertion of
    # payload-free telemetry. All values are synthetic; nothing is exported.
    owner = self()
    id = "bandit-local-metadata-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:bandit, :request, :start],
      fn _, _, metadata, _ ->
        send(owner, {:bandit_request, metadata.conn})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    server =
      start_supervised!(
        {Bandit, plug: LovelaceWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok =
      :gen_tcp.send(
        socket,
        "GET /oauth/google/callback?code=synthetic-code&state=synthetic-state HTTP/1.1\r\n" <>
          "Host: localhost:#{port}\r\nAuthorization: synthetic-header\r\nConnection: close\r\n\r\n"
      )

    assert {:ok, response} = :gen_tcp.recv(socket, 0, 2000)
    assert response =~ "303"
    assert_receive {:bandit_request, conn}, 2000
    assert conn.query_string == "code=synthetic-code&state=synthetic-state"
    assert {"authorization", "synthetic-header"} in conn.req_headers
  end
end
