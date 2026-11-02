defmodule LovelaceWeb.OwnerControllerTest do
  use LovelaceWeb.ConnCase, async: false
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
  end

  test "login rotates browser session and lock revokes its token", %{conn: conn} do
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
    conn = conn |> recycle() |> post("/lock")
    assert redirected_to(conn) == "/unlock"
    refute get_session(conn, :owner_session_token)
    assert {:error, _} = Owner.verify_session(token)
  end

  test "login failure is generic and never echoes credentials", %{conn: conn} do
    configure()
    conn = post_password(conn, "private wrong value")
    response = html_response(conn, 401)
    assert response =~ "Unable to unlock"
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

  defp post_password(conn, password) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/unlock", URI.encode_query(%{"password" => password}))
  end

  defp configure, do: Owner.configure!(@password, actor: %{role: :owner_setup})
end
