defmodule LovelaceWeb.OwnerAuthTest do
  use LovelaceWeb.ConnCase, async: false
  alias Lovelace.Owner
  alias Lovelace.Owner.Actions
  alias LovelaceWeb.OwnerAuth
  alias LovelaceWeb.Plugs.RequireOwner
  @service [actor: %{role: :owner_auth_service}]

  test "HTTP boundary fails closed without an owner or session", %{conn: conn} do
    conn = conn |> init_test_session(%{}) |> RequireOwner.call([])
    assert conn.halted
    assert redirected_to(conn) == "/unlock"
    refute Map.has_key?(conn.assigns, :current_actor)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "HTTP boundary mints capability only for a valid owner session", %{conn: conn} do
    {token, _} = session()
    conn = conn |> init_test_session(%{owner_session_token: token}) |> RequireOwner.call([])
    refute conn.halted
    assert conn.assigns.current_actor == %{role: :local_owner}
    refute Map.has_key?(conn.assigns, :owner_session_token)
    Owner.logout!(token)

    conn =
      conn
      |> recycle()
      |> init_test_session(%{owner_session_token: token})
      |> RequireOwner.call([])

    assert redirected_to(conn) == "/unlock"
  end

  test "LiveView mount rejects missing credentials" do
    assert {:halt, socket} = OwnerAuth.on_mount(:require_owner, %{}, %{}, socket())
    assert socket.redirected == {:redirect, %{to: "/unlock", status: 302}}
  end

  test "LiveView event and navigation hooks recheck revocation without credential assigns" do
    {token, _} = session()

    assert {:cont, socket} =
             OwnerAuth.on_mount(:require_owner, %{}, %{"owner_session_token" => token}, socket())

    assert socket.assigns.current_actor == %{role: :local_owner}
    refute inspect(socket.assigns) =~ token
    refute inspect(socket.assigns) =~ Actions.digest(token)
    lifecycle = socket.private.lifecycle
    [event_hook] = lifecycle.handle_event
    [params_hook] = lifecycle.handle_params
    assert {:cont, _} = event_hook.function.("save", %{}, socket)
    Owner.logout!(token)
    assert {:halt, locked} = event_hook.function.("save", %{}, socket)
    assert locked.redirected == {:redirect, %{to: "/unlock", status: 302}}
    assert {:halt, _} = params_hook.function.(%{}, "http://localhost/", socket)
  end

  test "connected LiveViews subscribe to their session logout topic" do
    {token, record} = session()
    connected = %{socket() | transport_pid: self()}

    assert {:cont, _socket} =
             OwnerAuth.on_mount(:require_owner, %{}, %{"owner_session_token" => token}, connected)

    Owner.logout!(token)
    topic = Actions.topic(record.digest)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
  end

  test "LiveView hooks reject absolute expiry and disconnect messages" do
    {token, record} = session()

    {:cont, socket} =
      OwnerAuth.on_mount(:require_owner, %{}, %{"owner_session_token" => token}, socket())

    Owner.delete_session!(record, @service)
    Owner.issue_session!(record.digest, DateTime.add(DateTime.utc_now(), -1), @service)
    [event_hook] = socket.private.lifecycle.handle_event
    assert {:halt, _} = event_hook.function.("save", %{}, socket)
    [info_hook] = socket.private.lifecycle.handle_info
    assert {:halt, _} = info_hook.function.({:owner_session_expired, record.digest}, socket)

    assert {:halt, _} =
             info_hook.function.(%Phoenix.Socket.Broadcast{event: "disconnect"}, socket)
  end

  defp session do
    Owner.configure!("a long local test password", actor: %{role: :owner_setup})
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    record =
      Owner.issue_session!(
        Actions.digest(token),
        DateTime.add(DateTime.utc_now(), 3600),
        @service
      )

    {token, record}
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      endpoint: LovelaceWeb.Endpoint,
      router: LovelaceWeb.Router,
      assigns: %{__changed__: %{}},
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end
end
