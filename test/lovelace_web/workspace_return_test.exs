defmodule LovelaceWeb.WorkspaceReturnTest do
  use LovelaceWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Lovelace.Mail.OAuth
  alias Lovelace.Owner
  alias LovelaceWeb.WorkspaceReturn

  @destination "/connections/gemini?gemini=removed"
  @token "synthetic-existing-owner-session"

  test "local 302 and 303 returns preserve the exact query and activate only once" do
    for status <- [302, 303] do
      response = redirect_response(%{owner_session_token: @token}, @destination, status)
      marker = get_session(response, :workspace_return)
      assert marker["destination"] == @destination
      assert marker["expires_at"] > System.system_time(:second)
      assert marker["expires_at"] <= System.system_time(:second) + 60
      refute inspect(marker) =~ @token

      returned = consume(response, @destination)
      assert WorkspaceReturn.live_session(returned) == %{"workspace_return" => true}
      refute get_session(returned, :workspace_return)
      assert get_session(returned, :owner_session_token) == @token

      reloaded = consume(returned, @destination)
      assert WorkspaceReturn.live_session(reloaded) == %{"workspace_return" => false}
    end
  end

  test "fresh visits and initial or replaced owner sessions do not create a return" do
    for session <- [%{}, %{owner_session_token: nil}, %{owner_session_token: ""}] do
      response = redirect_response(session, @destination)
      refute get_session(response, :workspace_return)

      initial_unlock =
        redirect_response(session, @destination, 302, fn conn ->
          put_session(conn, :owner_session_token, @token)
        end)

      refute get_session(initial_unlock, :workspace_return)
    end

    for update <- [
          &put_session(&1, :owner_session_token, "replacement-owner-session"),
          &delete_session(&1, :owner_session_token),
          &clear_session/1
        ] do
      response = redirect_response(%{owner_session_token: @token}, @destination, 303, update)
      refute get_session(response, :workspace_return)
    end

    direct = owner_request(%{owner_session_token: @token}, @destination)
    assert WorkspaceReturn.live_session(direct) == %{"workspace_return" => false}
  end

  test "external, authentication, unsafe and non-redirect responses cannot mark a return" do
    for destination <- [
          "https://untrusted.invalid/connections",
          "//untrusted.invalid/connections",
          "/unlock",
          "/setup",
          "/oauth/google/callback?code=private-code",
          "/connections/gemini?value=%0d%0aLocation:evil",
          "/unknown"
        ] do
      response = redirect_response(%{owner_session_token: @token}, destination)
      refute get_session(response, :workspace_return)
    end

    for status <- [200, 301, 307, 308] do
      response = redirect_response(%{owner_session_token: @token}, @destination, status)
      refute get_session(response, :workspace_return)
    end
  end

  test "a path or query mismatch consumes the marker instead of deferring activation" do
    for path <- ["/", "/connections/gemini", "/connections/gemini?gemini=saved"] do
      response = redirect_response(%{owner_session_token: @token}, @destination)
      mismatched = consume(response, path)
      refute mismatched.assigns.workspace_return
      refute get_session(mismatched, :workspace_return)
      refute consume(mismatched, @destination).assigns.workspace_return
    end
  end

  test "expired, malformed and differently bound markers fail closed and are deleted" do
    response = redirect_response(%{owner_session_token: @token}, @destination)
    marker = get_session(response, :workspace_return)

    for invalid <- [
          nil,
          true,
          @destination,
          %{},
          Map.put(marker, "expires_at", System.system_time(:second) - 1),
          Map.put(marker, "expires_at", System.system_time(:second) + 3600),
          Map.put(marker, "expires_at", "not-a-time"),
          Map.put(marker, "destination", "https://untrusted.invalid/"),
          Map.put(marker, "owner_digest", "another-owner")
        ] do
      returned =
        response
        |> get_session()
        |> Map.put("workspace_return", invalid)
        |> owner_request(@destination)

      refute returned.assigns.workspace_return
      refute get_session(returned, :workspace_return)
    end

    for token <- [nil, "", "replacement-owner-session"] do
      returned =
        response
        |> get_session()
        |> Map.put("owner_session_token", token)
        |> owner_request(@destination)

      refute returned.assigns.workspace_return
      refute get_session(returned, :workspace_return)
    end
  end

  test "HEAD and owner POST do not consume the next GET return" do
    response = redirect_response(%{owner_session_token: @token}, @destination)

    for method <- [:head, :post] do
      request =
        Plug.Test.conn(method, @destination)
        |> init_test_session(get_session(response))
        |> put_private(:owner_request_method, String.upcase(to_string(method)))
        |> Plug.Head.call([])
        |> WorkspaceReturn.call(:consume)

      refute request.assigns.workspace_return
      assert get_session(request, :workspace_return) == get_session(response, :workspace_return)
      assert consume(request, @destination).assigns.workspace_return
    end
  end

  test "an early credential redirect reaches disconnected and connected mounts exactly once", %{
    conn: conn
  } do
    start_supervised!(Lovelace.TestSupport.GeminiVault)
    previous = Application.get_env(:lovelace, :gemini_vault)
    Application.put_env(:lovelace, :gemini_vault, Lovelace.TestSupport.GeminiVault)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lovelace, :gemini_vault, previous),
        else: Application.delete_env(:lovelace, :gemini_vault)
    end)

    response =
      conn
      |> authenticate_owner()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/connections/gemini", "operation=remove")

    assert redirected_to(response, 303) == @destination
    assert get_session(response, :workspace_return)["destination"] == @destination

    returned = response |> recycle() |> get(@destination)
    assert returned.assigns.workspace_return
    refute get_session(returned, :workspace_return)
    assert html_response(returned, 200) =~ "data-enter-on-return=\"true\""
    {:ok, view, _html} = live(returned)
    assert has_element?(view, "#main-content[data-enter-on-return=true]")

    reloaded = returned |> recycle() |> get(@destination)
    refute reloaded.assigns.workspace_return
    {:ok, view, _html} = live(reloaded)
    refute has_element?(view, "#main-content[data-enter-on-return=true]")
  end

  test "an unlocked callback cancellation returns locally without a provider call", %{conn: conn} do
    conn = authenticate_owner(conn)

    workspace =
      Lovelace.Workspaces.create_workspace!("Return fixture", actor: %{role: :local_owner})

    {:ok, state, _} = OAuth.begin(workspace.id, get_session(conn, :owner_session_token))

    response =
      get(
        conn,
        "/oauth/google/callback?" <> URI.encode_query(%{state: state, error: "access_denied"})
      )

    destination = redirected_to(response, 303)
    assert get_session(response, :workspace_return)["destination"] == destination
    returned = response |> recycle() |> get(destination)
    assert returned.assigns.workspace_return
    refute get_session(returned, :workspace_return)
    reloaded = returned |> recycle() |> get(destination)
    refute reloaded.assigns.workspace_return
  end

  test "non-owner requests preserve a marker but static onboarding consumes it", %{conn: conn} do
    conn = authenticate_owner(conn)

    response =
      redirect_response(
        %{owner_session_token: get_session(conn, :owner_session_token)},
        "/onboarding"
      )

    conn = init_test_session(conn, get_session(response))
    marker = get_session(conn, :workspace_return)
    unlock_page = get(conn, "/unlock")
    assert html_response(unlock_page, 200)
    assert get_session(unlock_page, :workspace_return) == marker
    asset = unlock_page |> recycle() |> get("/images/distant-shore.svg")
    assert response(asset, 200)
    socket = asset |> recycle() |> get("/live/websocket")
    assert socket.status in [400, 403]

    static = socket |> recycle() |> get("/onboarding")
    assert redirected_to(static) == "/onboarding/workspace"
    assert static.assigns.workspace_return
    refute get_session(static, :workspace_return)

    workspace = static |> recycle() |> get("/")
    refute workspace.assigns.workspace_return
  end

  test "a marker cannot bypass missing, invalid or revoked owner authentication", %{conn: conn} do
    authenticated = authenticate_owner(conn)
    token = get_session(authenticated, :owner_session_token)
    response = redirect_response(%{owner_session_token: token}, @destination)
    session = get_session(response)

    for invalid <- [nil, "invalid-owner-session"] do
      refused =
        build_conn(:get, "http://localhost/")
        |> init_test_session(Map.put(session, "owner_session_token", invalid))
        |> get(@destination)

      assert redirected_to(refused) == "/unlock"
      refute get_session(refused, :workspace_return)
      refute Map.has_key?(refused.assigns, :current_actor)
    end

    Owner.logout!(token)

    revoked = authenticated |> init_test_session(session) |> get(@destination)
    assert redirected_to(revoked) == "/unlock"
    refute get_session(revoked, :workspace_return)
    refute Map.has_key?(revoked.assigns, :current_actor)
  end

  test "explicit lock invalidates a pending return even when its old cookie comes back", %{
    conn: conn
  } do
    authenticated = authenticate_owner(conn)
    token = get_session(authenticated, :owner_session_token)
    response = redirect_response(%{owner_session_token: token}, @destination)
    old_session = get_session(response)

    locked = post(authenticated, "/lock")
    assert redirected_to(locked) == "/unlock"
    refute get_session(locked, :workspace_return)

    returned =
      locked
      |> recycle()
      |> init_test_session(old_session)
      |> get(@destination)

    assert redirected_to(returned) == "/unlock"
    refute get_session(returned, :workspace_return)
    refute Map.has_key?(returned.assigns, :current_actor)
  end

  defp redirect_response(session, destination, status \\ 303, update \\ &Function.identity/1) do
    Plug.Test.conn(:post, "/synthetic-return")
    |> init_test_session(session)
    |> WorkspaceReturn.call(:capture)
    |> update.()
    |> put_resp_header("location", destination)
    |> send_resp(status, "")
  end

  defp consume(conn, destination), do: owner_request(get_session(conn), destination)

  defp owner_request(session, destination) do
    Plug.Test.conn(:get, destination)
    |> init_test_session(session)
    |> WorkspaceReturn.call(:consume)
  end
end
