defmodule Lovelace.TestSupport.VaultHTTPScenario.Adapter do
  @moduledoc false
  @behaviour Plug.Conn.Adapter
  alias Plug.Adapters.Test.Conn, as: TestConn

  @impl true
  def send_resp(state, status, headers, body) do
    %{observer: observer, scenario: scenario} = state
    send(observer, {:http_sending, scenario, self(), status, headers, IO.iodata_length(body)})

    receive do
      {:transmit, ^scenario} ->
        result = TestConn.send_resp(state, status, headers, body)
        send(observer, {:http_transmitted, scenario})
        result
    end
  end

  @impl true
  defdelegate send_file(state, status, headers, path, offset, length), to: Plug.Adapters.Test.Conn
  @impl true
  defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
  @impl true
  defdelegate chunk(state, body), to: Plug.Adapters.Test.Conn
  @impl true
  defdelegate read_req_body(state, options), to: Plug.Adapters.Test.Conn
  @impl true
  defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn
  @impl true
  defdelegate upgrade(state, protocol, options), to: Plug.Adapters.Test.Conn
  @impl true
  defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
  @impl true
  defdelegate get_sock_data(state), to: Plug.Adapters.Test.Conn
  @impl true
  defdelegate get_ssl_data(state), to: Plug.Adapters.Test.Conn
  @impl true
  defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn
end

defmodule Lovelace.TestSupport.VaultHTTPScenario do
  @moduledoc false
  import ExUnit.Assertions

  alias Lovelace.Owner
  alias Lovelace.Security.Vault
  alias Lovelace.StageDesigner.{Scene, Settings, Storage}
  alias Lovelace.TestSupport.PNG
  alias Lovelace.TestSupport.VaultHTTPScenario.Adapter

  def run(token, options) do
    assert Vault.enabled?()
    assert Vault.open?()
    assert {:ok, _} = Owner.verify_session(token)
    password = Keyword.fetch!(options, :password)
    path = if Keyword.get(options, :generated_image), do: generated_image(), else: "/workspaces"

    cache =
      if Keyword.get(options, :generated_image),
        do: "private, max-age=86400, immutable",
        else: "no-store"

    observer = self()
    completed_tag = make_ref()
    blocked_tag = make_ref()
    {completed, completed_monitor} = request(observer, completed_tag, token, path)

    try do
      assert_sending(completed_tag, completed, cache)
      send(completed, {:transmit, completed_tag})
      assert_receive {:http_transmitted, ^completed_tag}, 10_000
      assert_receive {:http_finished, ^completed_tag, :sent}, 10_000

      {blocked, blocked_monitor} = request(observer, blocked_tag, token, path)

      try do
        assert_sending(blocked_tag, blocked, cache)
        assert {:ok, true} = Owner.lock_all(actor: %{role: :local_owner})
        refute Process.alive?(blocked)
        assert_receive {:DOWN, ^blocked_monitor, :process, ^blocked, :killed}, 10_000
        refute Vault.open?()

        # A finished request may remain alive for HTTP keepalive without retaining a lease.
        assert Process.alive?(completed)
        send(blocked, {:transmit, blocked_tag})
        refute_receive {:http_transmitted, ^blocked_tag}
        refute_receive {:http_finished, ^blocked_tag, _}
        assert {:error, _} = Owner.verify_session(token)
        assert {:ok, fresh_token} = Owner.unlock(password, "http-after-global-lock")
        assert Vault.open?()
        assert {:ok, _} = Owner.verify_session(fresh_token)
        {:ok, fresh_token}
      after
        stop_request(blocked, blocked_monitor)
      end
    after
      stop_request(completed, completed_monitor)
    end
  end

  defp request(observer, scenario, token, path) do
    spawn_monitor(fn ->
      conn =
        :get
        |> Plug.Test.conn("http://localhost" <> path)
        |> Plug.Test.init_test_session(%{owner_session_token: token})

      {_, payload} = conn.adapter
      payload = Map.merge(payload, %{observer: observer, scenario: scenario})
      conn = %{conn | adapter: {Adapter, payload}}
      response = LovelaceWeb.Endpoint.call(conn, LovelaceWeb.Endpoint.init([]))
      send(observer, {:http_finished, scenario, response.state})

      receive do
        :finish -> :ok
      end
    end)
  end

  defp assert_sending(scenario, request, cache) do
    assert_receive {:http_sending, ^scenario, ^request, status, headers, bytes}, 10_000
    assert status == 200
    assert {"cache-control", cache} in headers
    assert bytes > 0
  end

  defp generated_image do
    assert {:ok, digest} = Storage.store(Settings.get(), PNG.image())
    assert {:ok, _} = Scene.publish(digest, DateTime.utc_now())
    Storage.url(digest)
  end

  defp stop_request(pid, monitor) do
    Process.exit(pid, :kill)
    Process.demonitor(monitor, [:flush])
  end
end
