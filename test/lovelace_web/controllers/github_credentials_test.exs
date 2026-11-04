defmodule LovelaceWeb.GitHubCredentialsTest do
  use LovelaceWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  alias Lovelace.GitHub.Auth
  alias Lovelace.Owner.Actions
  alias LovelaceWeb.Plugs.GitHubCredentials

  setup %{conn: conn} do
    start_supervised!({Lovelace.TestGitHub, []})

    settings = [
      github_provider: Lovelace.TestGitHub,
      github_keychain: Lovelace.TestGitHubKeychain,
      github: [client_id: "Iv1.synthetic", app_slug: "lovelace-synthetic"]
    ]

    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:lovelace, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:lovelace, key, value) end)
    conn = authenticate_owner(conn)
    session = get_session(conn, :owner_session_token)

    on_exit(fn ->
      Auth.cancel(session)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lovelace, key)
        {key, value} -> Application.put_env(:lovelace, key, value)
      end)
    end)

    %{conn: conn, session: session}
  end

  test "sign-in intent bypasses instrumentation and exposes only the session's user code", %{
    conn: conn,
    session: session
  } do
    owner = self()
    handler = "github-authorization-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:phoenix, :endpoint, :start], [:phoenix, :router_dispatch, :start]],
      fn event, _, metadata, _ -> send(owner, {:instrumented, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    logs =
      capture_log(fn ->
        response = submit(conn, %{"operation" => "sign_in"})
        assert redirected_to(response, 303) == "/connections/github?github=pending"
        assert response.params == %{}
        assert response.body_params == %{}
        assert get_resp_header(response, "cache-control") == ["no-store"]
        assert pending(session).status == :pending
        other = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        Lovelace.Owner.issue_session!(
          Actions.digest(other),
          DateTime.add(DateTime.utc_now(), 3600),
          actor: %{role: :owner_auth_service}
        )

        assert Auth.status(Actions.digest(other)) == %{status: :idle}
        status = Auth.status(Actions.digest(session))
        assert Map.keys(status) |> Enum.sort() == [:status, :user_code]
        assert Auth.cancel(session) == :ok
        assert Auth.status(Actions.digest(session)) == %{status: :idle}
      end)

    refute logs =~ "synthetic_device_secret"
    refute_receive {:instrumented, _, _}
  end

  test "missing CSRF and revoked sessions cannot start authorization", %{
    conn: conn,
    session: session
  } do
    conn = conn |> put_private(:plug_skip_csrf_protection, false) |> get("/connections/github")

    [csrf] =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#owner-lock-form input[name=_csrf_token]")
      |> LazyHTML.attribute("value")

    for token <- [nil, "invalid"] do
      refused =
        conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> submit(%{"operation" => "sign_in", "_csrf_token" => token})

      assert refused.status == 403
      assert refused.params == %{}
      assert refused.body_params == %{}
    end

    Lovelace.Owner.logout(session)

    refused =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> submit(%{"operation" => "sign_in", "_csrf_token" => csrf})

    assert redirected_to(refused, 303) == "/unlock"
    assert Lovelace.TestGitHub.state().calls == []
  end

  test "removed PAT submission cannot contact GitHub or store a credential", %{conn: conn} do
    logs =
      capture_log(fn ->
        response =
          submit(conn, %{
            "operation" => "connect",
            "login" => "synthetic",
            "token" => "synthetic_old_private_token"
          })

        assert redirected_to(response, 303) == "/connections/github?github=failed"
        assert response.params == %{}
        assert response.body_params == %{}
        assert Lovelace.TestGitHub.state().calls == []
        assert Lovelace.TestGitHub.state().tokens == %{}
      end)

    refute logs =~ "synthetic_old_private_token"
  end

  test "unconfigured app returns setup guidance without contacting GitHub", %{conn: conn} do
    Application.put_env(:lovelace, :github, [])
    response = submit(conn, %{"operation" => "sign_in"})
    assert redirected_to(response, 303) == "/connections/github?github=configuration"
    assert Lovelace.TestGitHub.state().calls == []
  end

  test "aliases cannot bypass early intent consumption and rejected input is scrubbed" do
    for path <- ["/connections/github", "/connections/github/", "/connections/%67ithub"] do
      response =
        Plug.Test.conn(:post, path, "operation=sign_in")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> init_test_session(%{})
        |> put_private(:plug_skip_csrf_protection, true)
        |> GitHubCredentials.call([])

      assert response.halted
      assert get_resp_header(response, "location") == ["/unlock"]
      assert response.params == %{}
      assert response.body_params == %{}
    end

    for {method, path, body} <- [
          {:put, "/connections/github", "token=synthetic-private-token"},
          {:post, "/connections/github?token=synthetic-private-token", ""},
          {:post, "/connections/github", String.duplicate("x", 17_000)}
        ] do
      response =
        Plug.Test.conn(method, path, body)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> init_test_session(%{})
        |> put_private(:plug_skip_csrf_protection, true)
        |> GitHubCredentials.call([])

      assert response.status == 400
      assert response.halted
      assert response.params == %{}
      assert response.body_params == %{}
      assert response.query_string == ""
      refute response.resp_body =~ "synthetic-private-token"
    end
  end

  defp pending(session, attempts \\ 100)
  defp pending(_, 0), do: flunk("GitHub device authorization did not become pending")

  defp pending(session, attempts) do
    case Auth.status(Actions.digest(session)) do
      %{status: :pending} = status ->
        status

      _ ->
        Process.sleep(10)
        pending(session, attempts - 1)
    end
  end

  defp submit(conn, params) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/connections/github", URI.encode_query(params))
  end
end
