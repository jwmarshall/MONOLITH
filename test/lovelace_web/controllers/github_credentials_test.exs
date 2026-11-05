defmodule LovelaceWeb.GitHubCredentialsTest do
  use LovelaceWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  alias Lovelace.GitHub.Auth
  alias Lovelace.Owner.Actions
  alias LovelaceWeb.Plugs.GitHubCredentials
  alias Plug.Conn.Query

  setup %{conn: conn} do
    start_supervised!({Lovelace.TestGitHub, []})

    settings = [
      github_provider: Lovelace.TestGitHub,
      github_keychain: Lovelace.TestGitHubKeychain
    ]

    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:lovelace, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:lovelace, key, value) end)
    conn = authenticate_owner(conn)
    session = get_session(conn, :owner_session_token)

    assert {:ok, true} =
             Lovelace.GitHub.save_client_credentials(
               "Iv1.synthetic",
               "synthetic_client_secret",
               "lovelace-synthetic",
               actor: %{role: :local_owner}
             )

    on_exit(fn ->
      Auth.cancel(session)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lovelace, key)
        {key, value} -> Application.put_env(:lovelace, key, value)
      end)
    end)

    %{conn: conn, session: session}
  end

  test "sign-in redirects directly to OAuth without exposing secrets to instrumentation", %{
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
        url = redirected_to(response, 303)
        assert String.starts_with?(url, "https://github.com/login/oauth/authorize?")
        params = URI.decode_query(URI.parse(url).query)
        assert params["client_id"] == "Iv1.synthetic"
        assert params["redirect_uri"] == Auth.callback_url()
        refute Map.has_key?(params, "client_secret")
        assert response.params == %{}
        assert response.body_params == %{}
        assert get_resp_header(response, "cache-control") == ["no-store"]
        assert Auth.status(Actions.digest(session)).status == :pending
        other = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        Lovelace.Owner.issue_session!(
          Actions.digest(other),
          DateTime.add(DateTime.utc_now(), 3600),
          actor: %{role: :owner_auth_service}
        )

        assert Auth.status(Actions.digest(other)) == %{status: :idle}
        status = Auth.status(Actions.digest(session))
        assert Map.keys(status) == [:status]
        assert Auth.cancel(session) == :ok
        assert Auth.status(Actions.digest(session)) == %{status: :idle}
      end)

    refute logs =~ "synthetic_client_secret"
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
      end)

    refute logs =~ "synthetic_old_private_token"
  end

  test "unconfigured app returns setup guidance without contacting GitHub", %{conn: conn} do
    Lovelace.TestGitHub.configure(tokens: %{})
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

  test "client settings save locally without provider contact and never expose secrets", %{
    conn: conn
  } do
    logs =
      capture_log(fn ->
        response =
          submit(conn, %{
            "operation" => "save_client",
            "client_id" => "Iv1.new",
            "client_secret" => "private_new_secret",
            "app_slug" => "new-readonly-app"
          })

        assert redirected_to(response, 303) == "/connections/github?github=settings_saved"
        assert response.params == %{}
        assert response.body_params == %{}

        assert {:ok, %{configured?: true, client_id: "Iv1.new", app_slug: "new-readonly-app"}} =
                 Lovelace.GitHub.client_status(actor: %{role: :local_owner})

        assert Lovelace.TestGitHub.state().calls == []
      end)

    refute logs =~ "private_new_secret"

    assert {:error, _} =
             Lovelace.GitHub.save_client_credentials(
               "Iv1.attacker",
               "attacker_secret",
               "attacker",
               actor: nil
             )

    assert {:ok, %{client_id: "Iv1.new"}} =
             Lovelace.GitHub.client_status(actor: %{role: :local_owner})
  end

  test "failed client saves do not replace the current stored client", %{conn: conn} do
    for secret <- ["", "bad secret", "line\nbreak"] do
      response =
        submit(conn, %{
          "operation" => "save_client",
          "client_id" => "Iv1.new",
          "client_secret" => secret,
          "app_slug" => "new-app"
        })

      assert redirected_to(response, 303) == "/connections/github?github=settings_failed"
    end

    Lovelace.TestGitHub.configure(keychain_put_error: :unavailable)

    response =
      submit(conn, %{
        "operation" => "save_client",
        "client_id" => "Iv1.new",
        "client_secret" => "new_secret",
        "app_slug" => "new-app"
      })

    assert redirected_to(response, 303) == "/connections/github?github=settings_failed"

    assert {:ok, %{client_id: "Iv1.synthetic"}} =
             Lovelace.GitHub.client_status(actor: %{role: :local_owner})
  end

  test "callback exchanges once before instrumentation and scrubs code and state", %{
    conn: conn,
    session: session
  } do
    {:ok, url} = Auth.begin(session)
    state = URI.decode_query(URI.parse(url).query)["state"]
    owner = self()
    handler = "github-callback-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:phoenix, :endpoint, :start], [:phoenix, :router_dispatch, :start]],
      fn event, _, metadata, _ -> send(owner, {:instrumented, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    logs =
      capture_log(fn ->
        response =
          get(
            conn,
            "/auth/github/callback?" <>
              URI.encode_query(%{"state" => state, "code" => "private_callback_code"})
          )

        assert redirected_to(response, 303) == "/connections/github?github=authorized"
        assert response.params == %{}
        assert response.query_string == ""
        assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
      end)

    refute logs =~ "private_callback_code"
    refute logs =~ state
    refute_receive {:instrumented, _, _}

    assert Enum.count(
             Lovelace.TestGitHub.state().calls,
             &match?({:exchange_code, _, _, _, _, _}, &1)
           ) == 1
  end

  test "duplicate unknown malformed and denied callbacks cannot exchange tokens", %{
    conn: conn,
    session: session
  } do
    {:ok, url} = Auth.begin(session)
    state = URI.decode_query(URI.parse(url).query)["state"]

    for query <- [
          "state=#{state}&state=#{state}&code=private_code",
          "state=#{state}&code=private_code&extra=unexpected",
          "state=#{state}&code=private_code&error=access_denied",
          "state=#{state}&error=access_denied&error_description=private_detail"
        ] do
      response = conn |> recycle() |> get("/auth/github/callback?" <> query)
      assert redirected_to(response, 303) == "/connections/github?github=access_failed"
      assert response.query_string == ""
      assert response.params == %{}
    end

    response = conn |> recycle() |> get("/auth/github/callback?state=#{state}&code=private_code")
    assert redirected_to(response, 303) == "/connections/github?github=access_failed"
    assert Lovelace.TestGitHub.state().calls == []
  end

  test "repository selection cannot silently attach the entire owner", %{conn: conn} do
    for extra <- [%{}, %{"repository_ids" => []}] do
      response =
        submit(
          conn,
          Map.merge(
            %{
              "operation" => "attach_repositories",
              "workspace_id" => Ecto.UUID.generate(),
              "organization_id" => Ecto.UUID.generate()
            },
            extra
          )
        )

      assert redirected_to(response, 303) =~ "github=invalid_input"
    end

    assert %{memberships: []} = Lovelace.GitHub.directory!(actor: %{role: :local_owner})
  end

  defp issue_session do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Lovelace.Owner.issue_session!(
      Actions.digest(token),
      DateTime.add(DateTime.utc_now(), 3600),
      actor: %{role: :owner_auth_service}
    )

    token
  end

  defp submit(conn, params) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/connections/github", Query.encode(params))
  end
end
