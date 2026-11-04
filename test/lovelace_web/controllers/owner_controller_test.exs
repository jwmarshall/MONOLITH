defmodule LovelaceWeb.OwnerControllerTest do
  use LovelaceWeb.ConnCase, async: false
  require Phoenix.LiveViewTest
  alias Lovelace.Owner
  alias LovelaceWeb.OwnerUnlock
  @password "a long local test password"

  setup %{conn: conn} do
    if is_nil(Process.whereis(Owner.Throttle)), do: start_supervised!(Owner.Throttle)
    client = rem(System.unique_integer([:positive]), 254) + 1
    %{conn: %{conn | host: "localhost", remote_ip: {127, 0, 0, client}}}
  end

  test "unconfigured unlock offers terminal instructions, never web setup", %{conn: conn} do
    conn = get(conn, "/unlock")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(document, "#owner-setup-instructions") |> LazyHTML.to_html() =~
             "mix lovelace.owner.setup"

    assert LazyHTML.query(document, "#owner-unlock-form") |> Enum.empty?()
    assert_owner_stage(document)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "password form uses POST, CSRF, and no signup or identity field", %{conn: conn} do
    configure()
    document = conn |> get("/unlock") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(document, "#owner-unlock-form[method=post][action='/unlock']")
           |> Enum.any?()

    assert LazyHTML.query(document, "input[name=_csrf_token]") |> Enum.any?()
    assert LazyHTML.query(document, "input[type=password][name=password]") |> Enum.any?()
    assert LazyHTML.query(document, "input[name=email],input[name=username]") |> Enum.empty?()
    assert_owner_stage(document)
  end

  test "static owner screens share the local stage allowlist without LiveView hooks" do
    url = "/stage/background/#{String.duplicate("a", 64)}.jpg"

    for candidate <- [url, "https://remote.test/image.jpg", "/stage/background/not-a-digest.jpg"] do
      html =
        Phoenix.LiveViewTest.render_component(&LovelaceWeb.OwnerHTML.unlock/1,
          configured?: true,
          setup_state: :configured,
          error?: false,
          csrf_token: "synthetic-csrf",
          background: %{url: candidate, status: :ready}
        )

      document = LazyHTML.from_fragment(html)
      assert_owner_stage(document)

      images =
        LazyHTML.query(document, "#owner-stage-background img[data-static-stage-image=true]")

      if candidate == url do
        assert LazyHTML.attribute(images, "src") == [url]
        assert LazyHTML.attribute(images, "data-loaded") == []
      else
        assert Enum.empty?(images)
      end
    end
  end

  test "empty static and live stages share the persisted bundled default without creating scenes",
       %{conn: conn} do
    actor = %{role: :stage_designer}
    before = Lovelace.StageDesigner.get_state!(1, actor: actor)
    chosen = Lovelace.StageDesigner.initialize_default_scene!(%{}, actor: actor)
    url = "/images/scenes/#{chosen.digest}.jpg"
    static = conn |> get("/unlock") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(static, "#owner-stage-background") |> LazyHTML.attribute("style") ==
             ["--workspace-default-background: url('#{url}')"]

    {:ok, live, _} = conn |> authenticate_owner() |> Phoenix.LiveViewTest.live("/")
    assert Phoenix.LiveViewTest.has_element?(live, "#workspace-background[style*=\"#{url}\"]")
    refute Phoenix.LiveViewTest.has_element?(live, "#workspace-background img")
    assert Lovelace.StageDesigner.get_state!(1, actor: actor) == before
    assert Lovelace.StageDesigner.get_default_scene!(1, actor: actor).digest == chosen.digest
  end

  test "login rotates browser session and explicit lock revokes every session", %{conn: conn} do
    configure()
    old_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    Owner.issue_session!(Owner.Actions.digest(old_token), DateTime.add(DateTime.utc_now(), 60),
      actor: %{role: :owner_auth_service}
    )

    conn =
      conn
      |> init_test_session(%{unrelated: "old session", owner_session_token: old_token})
      |> post_password(@password)

    assert redirected_to(conn) == "/"
    token = get_session(conn, :owner_session_token)
    assert is_binary(token)
    refute get_session(conn, :unrelated)
    assert {:error, _} = Owner.verify_session(old_token)
    assert {:ok, _} = Owner.verify_session(token)
    {:ok, other_token} = Owner.unlock(@password, "another-browser")
    assert {:ok, _} = Owner.verify_session(other_token)
    conn = conn |> recycle() |> post("/lock")
    assert redirected_to(conn) == "/unlock"
    refute get_session(conn, :owner_session_token)
    assert {:error, _} = Owner.verify_session(token)
    assert {:error, _} = Owner.verify_session(other_token)
  end

  test "failed unlock retains the requested destination and success consumes it", %{conn: conn} do
    configure()

    destination =
      "/workspaces/synthetic-workspace/accounts/synthetic-account/mail/threads/synthetic-thread?q=quiet%20morning&page=2"

    conn = get(conn, destination)
    assert redirected_to(conn) == "/unlock"
    assert get_session(conn, :owner_return_to) == destination

    conn = conn |> recycle() |> get("/unlock")
    assert html_response(conn, 200)
    assert get_session(conn, :owner_return_to) == destination

    conn = conn |> recycle() |> post_password("incorrect synthetic password")
    assert html_response(conn, 401) =~ "Unable to unlock"
    assert get_session(conn, :owner_return_to) == destination
    refute get_session(conn, :owner_session_token)

    conn = conn |> recycle() |> post_password(@password)
    assert redirected_to(conn) == destination
    assert {:ok, _} = Owner.verify_session(get_session(conn, :owner_session_token))
    refute get_session(conn, :owner_return_to)
    assert conn.private.plug_session_info == :renew

    conn = conn |> recycle() |> post_password(@password)
    assert redirected_to(conn) == "/"
  end

  test "Settings deep links require unlock and resume the requested destination", %{conn: conn} do
    configure()
    conn = get(conn, "/settings")
    assert redirected_to(conn) == "/unlock"
    assert get_session(conn, :owner_return_to) == "/settings"

    conn = conn |> recycle() |> post_password(@password)
    assert redirected_to(conn) == "/settings"
    assert {:ok, _} = Owner.verify_session(get_session(conn, :owner_session_token))
    refute get_session(conn, :owner_return_to)
  end

  test "HEAD navigation cannot become a return destination after Plug.Head rewrites it", %{
    conn: conn
  } do
    conn =
      conn
      |> init_test_session(%{owner_return_to: "/?stale=destination"})
      |> head("/workspaces/synthetic-workspace?account=synthetic-account")

    assert redirected_to(conn) == "/unlock"
    assert conn.method == "GET"
    assert conn.private.owner_request_method == "HEAD"
    refute get_session(conn, :owner_return_to)
  end

  test "successful unlock revalidates stored destinations and ignores form return parameters", %{
    conn: conn
  } do
    configure()

    for destination <- [nil, "//external.test/", "/?q=%0a", "/unlock", "/oauth/google/callback"] do
      result =
        conn
        |> init_test_session(%{owner_return_to: destination})
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post(
          "/unlock",
          URI.encode_query(%{"password" => @password, "return_to" => "/?injected=true"})
        )

      assert redirected_to(result) == "/"
      refute get_session(result, :owner_return_to)
      refute Map.has_key?(result.params, "return_to")
      refute Map.has_key?(result.body_params, "return_to")
    end
  end

  test "explicit lock clears any return destination before ordinary unlock", %{conn: conn} do
    configure()

    conn = post_password(conn, @password)
    token = get_session(conn, :owner_session_token)

    conn =
      conn
      |> recycle()
      |> init_test_session(%{owner_session_token: token, owner_return_to: "/?stale=destination"})
      |> post("/lock")

    assert redirected_to(conn) == "/unlock"
    refute get_session(conn, :owner_return_to)
    refute get_session(conn, :owner_session_token)
    assert {:error, _} = Owner.verify_session(token)

    conn = conn |> recycle() |> post_password(@password)
    assert redirected_to(conn) == "/"
  end

  test "Lock rejects missing or invalid CSRF without revoking, then accepts the rendered token",
       %{
         conn: conn
       } do
    conn = authenticate_owner(conn)
    owner_token = get_session(conn, :owner_session_token)

    conn =
      conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> get("/")

    [csrf] =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#owner-lock-form input[name=_csrf_token]")
      |> LazyHTML.attribute("value")

    for params <- [%{}, %{"_csrf_token" => "invalid-synthetic-csrf"}] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> post("/lock", params)
      end

      assert {:ok, _} = Owner.verify_session(owner_token)
    end

    locked =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/lock", %{"_csrf_token" => csrf})

    assert redirected_to(locked) == "/unlock"
    assert {:error, _} = Owner.verify_session(owner_token)
  end

  test "login failure is generic and never echoes credentials", %{conn: conn} do
    configure()
    conn = post_password(conn, "private wrong value")
    response = html_response(conn, 401)
    assert response =~ "Unable to unlock"
    assert_owner_stage(LazyHTML.from_document(response))
    refute response =~ "private wrong value"
    refute get_session(conn, :owner_session_token)
  end

  test "a real CSRF token is accepted by the early boundary", %{conn: conn} do
    configure()
    conn = conn |> put_private(:plug_skip_csrf_protection, false) |> get("/unlock")

    [csrf] =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#owner-unlock-form input[name=_csrf_token]")
      |> LazyHTML.attribute("value")

    conn =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/unlock", URI.encode_query(%{"password" => @password, "_csrf_token" => csrf}))

    assert redirected_to(conn) == "/"
    assert {:ok, _} = Owner.verify_session(get_session(conn, :owner_session_token))
  end

  test "early password boundary refuses missing CSRF and query credentials" do
    configure()

    conn =
      Plug.Test.conn(:post, "/unlock", "password=private-wrong-value")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> init_test_session(%{})
      |> put_private(:plug_skip_csrf_protection, false)
      |> OwnerUnlock.call([])

    assert conn.status == 403
    assert conn.halted
    assert conn.params == %{}
    assert conn.body_params == %{}
    refute conn.resp_body =~ "private-wrong-value"

    conn =
      Plug.Test.conn(:post, "/unlock?password=ignored", "")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> init_test_session(%{})
      |> OwnerUnlock.call([])

    assert conn.status == 400
    refute get_session(conn, :owner_session_token)
  end

  test "successful early boundary scrubs password before returning its conn" do
    configure()

    conn =
      Plug.Test.conn(:post, "/unlock", URI.encode_query(%{"password" => @password}))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> init_test_session(%{})
      |> put_private(:plug_skip_csrf_protection, true)
      |> OwnerUnlock.call([])

    assert conn.status == 302
    assert conn.halted
    refute Map.has_key?(conn.params, "password")
    refute Map.has_key?(conn.body_params, "password")
    assert {:ok, _} = Owner.verify_session(get_session(conn, :owner_session_token))
  end

  test "password is absent from Phoenix and Ash telemetry", %{conn: conn} do
    configure()
    id = "owner-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    events =
      for prefix <- [
            [:phoenix, :endpoint],
            [:phoenix, :router_dispatch],
            [:phoenix, :controller, :render],
            [:ash, :owner, :action],
            [:ash, :owner, :read]
          ],
          suffix <- [:start, :stop, :exception],
          do: prefix ++ [suffix]

    :ok =
      :telemetry.attach_many(
        id,
        events,
        fn event, _measurements, metadata, _ ->
          send(parent, {:owner_telemetry, event, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    sentinel = "sentinel-private-password-never-in-telemetry"

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert conn |> post_password(sentinel) |> html_response(401)
      end)

    refute log =~ sentinel
    assert_receive {:owner_telemetry, _, metadata}
    refute contains_secret?(metadata, sentinel)
    assert_telemetry_redacted(sentinel)
  end

  defp assert_telemetry_redacted(sentinel) do
    receive do
      {:owner_telemetry, _event, metadata} ->
        refute contains_secret?(metadata, sentinel)
        assert_telemetry_redacted(sentinel)
    after
      0 -> :ok
    end
  end

  # Traverse raw struct fields too: Inspect redaction must not hide leaked metadata.
  defp contains_secret?(value, secret) when is_binary(value),
    do: :binary.match(value, secret) != :nomatch

  defp contains_secret?(value, secret) when is_map(value),
    do: contains_secret?(Map.to_list(value), secret)

  defp contains_secret?(value, secret) when is_tuple(value),
    do: contains_secret?(Tuple.to_list(value), secret)

  defp contains_secret?(value, secret) when is_list(value),
    do: Enum.any?(value, &contains_secret?(&1, secret))

  defp contains_secret?(_value, _secret), do: false

  defp assert_owner_stage(document) do
    for selector <- [
          "#owner-stage.glass-workspace.stage-static",
          "#owner-stage-background.workspace-background[aria-hidden=true]",
          "#owner-stage > #main-content.workspace-glass.owner-glass[aria-labelledby=owner-unlock-heading]",
          "#owner-unlock-heading.sr-only",
          "#owner-stage > #owner-stage-monogram.stage-monogram[aria-hidden=true][focusable=false] path"
        ] do
      assert document |> LazyHTML.query(selector) |> Enum.any?()
    end

    refute LazyHTML.to_html(document) =~ "Unlock your workspace"
    assert document |> LazyHTML.query(".owner-content > .text-primary") |> Enum.empty?()

    # Unlock/setup work without a socket or an entrance gate. The original SVG
    # remains underneath any generated image that hasn't loaded successfully.
    assert document
           |> LazyHTML.query("[inert], [phx-hook]")
           |> Enum.empty?()
  end

  defp post_password(conn, password) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/unlock", URI.encode_query(%{"password" => password}))
  end

  defp configure, do: Owner.configure!(@password, actor: %{role: :owner_setup})
end
