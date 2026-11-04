defmodule LovelaceWeb.OwnerAuthTest do
  use LovelaceWeb.ConnCase, async: false
  alias Lovelace.Owner
  alias Lovelace.Owner.Actions
  alias LovelaceWeb.OwnerAuth
  alias LovelaceWeb.OwnerReturnPath
  alias LovelaceWeb.Plugs.RequireOwner
  @service [actor: %{role: :owner_auth_service}]

  test "HTTP boundary fails closed without an owner or session", %{conn: conn} do
    conn = conn |> init_test_session(%{}) |> RequireOwner.call([])
    assert conn.halted
    assert redirected_to(conn) == "/unlock"
    refute Map.has_key?(conn.assigns, :current_actor)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "HTTP boundary retains a GET path and query while discarding the old session" do
    destination =
      "/workspaces/synthetic-workspace/accounts/synthetic-account/mail/threads/synthetic-thread?q=quiet%20morning&page=2"

    conn =
      Plug.Test.conn(:get, destination)
      |> init_test_session(%{owner_session_token: "invalid", unrelated: "discard me"})
      |> RequireOwner.call([])

    assert redirected_to(conn) == "/unlock"
    assert get_session(conn, :owner_return_to) == destination
    refute get_session(conn, :owner_session_token)
    refute get_session(conn, :unrelated)
    assert conn.private.plug_session_info == :renew
  end

  test "HTTP boundary never remembers non-GET requests or unapproved paths" do
    for {method, path} <- [
          {:post, "/oauth/google/start"},
          {:head, "/"},
          {:get, "/unlock"},
          {:get, "/not-an-application-route"},
          {:get, "/?q=%0d%0aLocation:evil"}
        ] do
      conn =
        Plug.Test.conn(method, path)
        |> init_test_session(%{owner_return_to: "/?stale=destination"})
        |> RequireOwner.call([])

      assert redirected_to(conn) == "/unlock"
      refute get_session(conn, :owner_return_to)
    end
  end

  test "return destinations reject external, ambiguous, control-bearing and non-application URLs" do
    for destination <- [
          nil,
          %{"path" => "/"},
          "https://external.test/",
          "//external.test/",
          "//external.test:invalid/",
          "https://external.test:invalid/",
          "/\\external.test/",
          "/%2f%2fexternal.test",
          "/%5cexternal.test",
          "/?q=%5cvalue",
          "/?q=back\\slash",
          "/?q=line\nbreak",
          "/?q=%0d%0aLocation:evil",
          "/?q=%00",
          "/?q=%7f",
          "/?q=%C2%85",
          "/?q=" <> <<255>>,
          "/?q=%ff",
          "/?q=raw space",
          "/#fragment",
          "/./",
          "/workspaces/../unlock",
          "/unlock",
          "/lock",
          "/setup",
          "/setup/password",
          "/oauth/google/start",
          "/oauth/google/callback?code=synthetic-code",
          "/stage/background/synthetic.jpg",
          "/dev/dashboard",
          "/unknown",
          "/?q=" <> String.duplicate("a", 2048)
        ] do
      assert OwnerReturnPath.safe(destination) == nil
    end
  end

  test "return destinations allow registered owner application routes with queries" do
    for path <- [
          "/",
          "/workspaces",
          "/workspaces/synthetic-workspace",
          "/workspaces/synthetic-workspace/integrations",
          "/workspaces/synthetic-workspace/accounts/synthetic-account/mail",
          "/workspaces/synthetic-workspace/accounts/synthetic-account/mail/threads/synthetic-thread",
          "/accounts/synthetic-account/mail",
          "/accounts/synthetic-account/mail/threads/synthetic-thread",
          "/connections",
          "/connections/gmail",
          "/onboarding",
          "/onboarding/audience",
          "/scenes",
          "/settings"
        ] do
      destination = path <> "?q=quiet%20morning&page=2"
      assert OwnerReturnPath.safe(destination) == destination
    end
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
