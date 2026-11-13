defmodule MonolithWeb.GitHubCredentialsTest do
  use MonolithWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  alias Monolith.ConnectionDiagnostics.State, as: DiagnosticState
  alias Monolith.GitHub
  alias Monolith.GitHub.{Auth, ClientCredentials, Credentials, Operations}
  alias Monolith.Owner.Actions
  alias Monolith.TestGitHub
  alias Monolith.TestSupport.{GitHubDiscovery, OAuthJobs}
  alias MonolithWeb.Plugs.GitHubCredentials
  alias Plug.Conn.Query
  @owner %{role: :local_owner}

  setup %{conn: conn} do
    start_supervised!({Monolith.TestGitHub, []})

    settings = [
      github_provider: Monolith.TestGitHub,
      github_keychain: Monolith.TestGitHubKeychain
    ]

    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:monolith, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:monolith, key, value) end)
    conn = authenticate_owner(conn)
    session = get_session(conn, :owner_session_token)

    assert {:ok, nil} =
             Ash.get(DiagnosticState, :github,
               actor: %{role: :connection_diagnostics},
               not_found_error?: false
             )

    assert {:ok, true} =
             Monolith.GitHub.save_client_credentials(
               "Iv1.synthetic",
               "synthetic_client_secret",
               "monolith-synthetic",
               actor: %{role: :local_owner}
             )

    on_exit(fn ->
      Auth.cancel(session)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:monolith, key)
        {key, value} -> Application.put_env(:monolith, key, value)
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

        Monolith.Owner.issue_session!(
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

    Monolith.Owner.logout(session)

    refused =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> submit(%{"operation" => "sign_in", "_csrf_token" => csrf})

    assert redirected_to(refused, 303) == "/unlock"
    assert Monolith.TestGitHub.state().calls == []
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
        assert Monolith.TestGitHub.state().calls == []
      end)

    refute logs =~ "synthetic_old_private_token"
  end

  test "unconfigured app returns setup guidance without contacting GitHub", %{conn: conn} do
    Monolith.TestGitHub.configure(tokens: %{})
    response = submit(conn, %{"operation" => "sign_in"})
    assert redirected_to(response, 303) == "/connections/github?github=configuration"
    assert Monolith.TestGitHub.state().calls == []
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
                 Monolith.GitHub.client_status(actor: %{role: :local_owner})

        assert Monolith.TestGitHub.state().calls == []
      end)

    refute logs =~ "private_new_secret"

    assert {:error, _} =
             Monolith.GitHub.save_client_credentials(
               "Iv1.attacker",
               "attacker_secret",
               "attacker",
               actor: nil
             )

    assert {:ok, %{client_id: "Iv1.new"}} =
             Monolith.GitHub.client_status(actor: %{role: :local_owner})
  end

  test "GitHub App URLs save only the canonical slug without provider contact", %{conn: conn} do
    for slug <- ["new-readonly-app", String.duplicate("a", 100)],
        suffix <- ["", "/"] do
      response =
        submit(conn, %{
          "operation" => "save_client",
          "client_id" => "Iv1.new",
          "client_secret" => "private_new_secret",
          "app_slug" => "https://github.com/apps/#{slug}#{suffix}"
        })

      assert redirected_to(response, 303) == "/connections/github?github=settings_saved"
      assert {:ok, %{app_slug: ^slug}} = ClientCredentials.current()
      assert TestGitHub.state().calls == []
    end
  end

  test "the equivalent app URL preserves pending sign-in and the stored generation", %{
    conn: conn,
    session: session
  } do
    {:ok, client} = ClientCredentials.current()
    {:ok, _url} = Auth.begin(session)

    response =
      submit(conn, %{
        "operation" => "save_client",
        "client_id" => "Iv1.synthetic",
        "client_secret" => "synthetic_client_secret",
        "app_slug" => "https://github.com/apps/monolith-synthetic/"
      })

    assert redirected_to(response, 303) == "/connections/github?github=settings_saved"
    assert {:ok, ^client} = ClientCredentials.current()
    assert Auth.status(Actions.digest(session)).status == :pending
  end

  test "unrelated or malformed app URLs cannot replace stored credentials", %{conn: conn} do
    initial = TestGitHub.state().tokens

    for url <- [
          "http://github.com/apps/private-app",
          "https://github.com.evil.example/apps/private-app",
          "https://github.com@evil.example/apps/private-app",
          "https://user@github.com/apps/private-app",
          "https://github.com:443/apps/private-app",
          "https://github.com/settings/apps/private-app",
          "https://github.com/apps/private-app/installations/new",
          "https://github.com/apps/private-app?other=1",
          "https://github.com/apps/private-app#fragment",
          "https://github.com/apps/private-app//",
          "https://github.com/apps/%70rivate-app",
          "https://github.com/apps/#{String.duplicate("a", 101)}"
        ] do
      response =
        submit(conn, %{
          "operation" => "save_client",
          "client_id" => "Iv1.new",
          "client_secret" => "private_new_secret",
          "app_slug" => url
        })

      assert redirected_to(response, 303) == "/connections/github?github=invalid_app_slug"
      assert TestGitHub.state().tokens == initial
      assert TestGitHub.state().calls == []
    end
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

      assert redirected_to(response, 303) == "/connections/github?github=invalid_client_secret"
    end

    Monolith.TestGitHub.configure(keychain_put_error: :unavailable)

    response =
      submit(conn, %{
        "operation" => "save_client",
        "client_id" => "Iv1.new",
        "client_secret" => "new_secret",
        "app_slug" => "new-app"
      })

    assert redirected_to(response, 303) == "/connections/github?github=keychain_failed"

    assert {:ok, %{client_id: "Iv1.synthetic"}} =
             Monolith.GitHub.client_status(actor: %{role: :local_owner})
  end

  test "invalid client fields identify only the field and preserve stored credentials", %{
    conn: conn
  } do
    initial = TestGitHub.state().tokens

    for {field, value} <- [
          {"client_id", " private-client-id "},
          {"client_id", String.duplicate("a", 129)},
          {"client_secret", "private secret"},
          {"client_secret", String.duplicate("a", 1025)},
          {"app_slug", "https://example.com/apps/private-app"},
          {"app_slug", String.duplicate("a", 101)}
        ] do
      fields =
        Map.put(
          %{
            "operation" => "save_client",
            "client_id" => "Iv1.new",
            "client_secret" => "private_new_secret",
            "app_slug" => "new-readonly-app"
          },
          field,
          value
        )

      logs =
        capture_log(fn ->
          response = submit(conn, fields)
          destination = redirected_to(response, 303)
          assert destination == "/connections/github?github=invalid_#{field}"
          assert response.params == %{}
          assert response.body_params == %{}
          refute destination =~ value
          refute destination =~ "private_new_secret"
        end)

      refute logs =~ value
      refute logs =~ "private_new_secret"
      assert TestGitHub.state().tokens == initial
      assert TestGitHub.state().calls == []
    end
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
          OAuthJobs.get(
            conn,
            "/auth/github/callback?" <>
              URI.encode_query(%{
                "state" => state,
                "code" => "private_callback_code",
                "iss" => "https://github.com/login/oauth"
              })
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
             Monolith.TestGitHub.state().calls,
             &match?({:exchange_code, _, _, _, _, _}, &1)
           ) == 1
  end

  test "invalid or duplicated issuers cannot exchange tokens or consume a valid request", %{
    conn: conn,
    session: session
  } do
    {:ok, url} = Auth.begin(session)
    state = URI.decode_query(URI.parse(url).query)["state"]
    tokens = TestGitHub.state().tokens
    query = URI.encode_query(%{"state" => state, "code" => "private_code"})
    issuer = URI.encode_query(%{"iss" => "https://github.com/login/oauth"})

    for invalid <- [
          URI.encode_query(%{"iss" => ""}),
          URI.encode_query(%{"iss" => "https://attacker.invalid/login/oauth"}),
          URI.encode_query(%{"iss" => "http://github.com/login/oauth"}),
          URI.encode_query(%{"iss" => "https://github.com/login/oauth/"}),
          URI.encode_query(%{"iss" => "https://github.com/login/oauth?unexpected=1"}),
          URI.encode_query(%{"iss" => "https://github.com/login/oauth#unexpected"}),
          issuer <> "&" <> issuer
        ] do
      response =
        OAuthJobs.get(
          conn,
          "/auth/github/callback?" <> query <> "&" <> invalid
        )

      assert redirected_to(response, 303) == "/connections/github?github=callback_invalid"
      assert response.query_string == ""
      assert response.params == %{}
      assert Auth.status(Actions.digest(session)) == %{status: :pending}
      assert TestGitHub.state().calls == []
      assert TestGitHub.state().tokens == tokens
      assert directory().connections == []
    end

    accepted =
      OAuthJobs.get(conn, "/auth/github/callback?" <> query <> "&" <> issuer)

    assert redirected_to(accepted, 303) == "/connections/github?github=authorized"
    assert [%{status: :ready}] = directory().connections

    calls = TestGitHub.state().calls

    replay =
      OAuthJobs.get(conn, "/auth/github/callback?" <> query <> "&" <> issuer)

    assert redirected_to(replay, 303) == "/connections/github?github=authorization_unmatched"
    assert TestGitHub.state().calls == calls
  end

  test "a denial from GitHub's issuer consumes only its matching attempt without exchanging", %{
    conn: conn,
    session: session
  } do
    {:ok, url} = Auth.begin(session)
    state = URI.decode_query(URI.parse(url).query)["state"]

    query =
      URI.encode_query(%{
        "state" => state,
        "error" => "access_denied",
        "error_description" => "private_denial_detail",
        "iss" => "https://github.com/login/oauth"
      })

    response = OAuthJobs.get(conn, "/auth/github/callback?" <> query)
    assert redirected_to(response, 303) == "/connections/github?github=authorization_denied"
    assert Auth.status(Actions.digest(session)) == %{status: :failed}
    assert TestGitHub.state().calls == []
    assert directory().connections == []
    refute response.resp_body =~ "private_denial_detail"

    replay = OAuthJobs.get(conn, "/auth/github/callback?" <> query)
    assert redirected_to(replay, 303) == "/connections/github?github=authorization_unmatched"
    assert TestGitHub.state().calls == []
  end

  test "duplicate unknown malformed and denied callbacks cannot exchange tokens", %{
    conn: conn,
    session: session
  } do
    {:ok, url} = Auth.begin(session)
    state = URI.decode_query(URI.parse(url).query)["state"]

    for {query, notice} <- [
          {"state=#{state}&state=#{state}&code=private_code", "callback_invalid"},
          {"state=#{state}&code=private_code&extra=unexpected", "callback_invalid"},
          {"state=#{state}&code=private_code&error=access_denied", "callback_invalid"},
          {"state=#{state}&error=access_denied&error_description=private_detail",
           "authorization_denied"}
        ] do
      response = OAuthJobs.get(conn, "/auth/github/callback?" <> query)
      assert redirected_to(response, 303) == "/connections/github?github=#{notice}"
      assert get_session(response, :github_authorization_result) == notice
      assert response.query_string == ""
      assert response.params == %{}
    end

    response = get(conn, "/auth/github/callback?state=#{state}&code=private_code")
    assert redirected_to(response, 303) == "/connections/github?github=authorization_unmatched"
    assert Monolith.TestGitHub.state().calls == []
  end

  test "an unlinked callback preserves pending authorization and a fresh sign-in clears recovery",
       %{
         conn: conn,
         session: session
       } do
    {:ok, old_url} = Auth.begin(session)
    old_state = URI.decode_query(URI.parse(old_url).query)["state"]
    returned = get(conn, "/auth/github/callback?code=private_unlinked_code")
    assert redirected_to(returned, 303) == "/connections/github?github=authorization_unlinked"
    assert get_session(returned, :github_authorization_result) == "authorization_unlinked"
    assert Auth.status(Actions.digest(session)) == %{status: :pending}
    assert TestGitHub.state().calls == []
    assert directory().connections == []

    restarted = submit(recycle(returned), %{"operation" => "sign_in"})
    assert get_session(restarted, :github_authorization_result) == nil
    state = URI.decode_query(URI.parse(redirected_to(restarted, 303)).query)["state"]
    refute state == old_state

    stale =
      restarted
      |> recycle()
      |> OAuthJobs.get(
        "/auth/github/callback?" <> URI.encode_query(%{"state" => old_state, "code" => "stale"})
      )

    assert redirected_to(stale, 303) == "/connections/github?github=authorization_unmatched"
    assert Auth.status(Actions.digest(session)) == %{status: :pending}
    assert TestGitHub.state().calls == []

    accepted =
      stale
      |> recycle()
      |> OAuthJobs.get(
        "/auth/github/callback?" <> URI.encode_query(%{"state" => state, "code" => "accepted"})
      )

    assert redirected_to(accepted, 303) == "/connections/github?github=authorized"
    assert get_session(accepted, :github_authorization_result) == nil
    assert [%{status: :ready}] = directory().connections
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

    assert %{memberships: []} = Monolith.GitHub.directory!(actor: %{role: :local_owner})
  end

  test "cancelling sign-in invalidates only the current owner's pending callback", %{
    conn: conn,
    session: session
  } do
    {:ok, url} = Auth.begin(session)
    state = URI.decode_query(URI.parse(url).query)["state"]
    other = issue_session()
    on_exit(fn -> Auth.cancel(other) end)
    assert {:ok, _} = Auth.begin(other)
    tokens = TestGitHub.state().tokens

    response = submit(conn, %{"operation" => "cancel_sign_in"})
    assert redirected_to(response, 303) == "/connections/github?github=cancelled"
    assert Auth.status(Actions.digest(session)) == %{status: :idle}
    assert Auth.status(Actions.digest(other)) == %{status: :pending}

    callback =
      conn
      |> recycle()
      |> OAuthJobs.get(
        "/auth/github/callback?" <> URI.encode_query(%{"state" => state, "code" => "late"})
      )

    assert redirected_to(callback, 303) == "/connections/github?github=authorization_unmatched"
    assert directory().connections == []
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  test "cancelling a completed sign-in reports authorization without deleting the account", %{
    conn: conn,
    session: session
  } do
    {:ok, url} = Auth.begin(session)
    state = URI.decode_query(URI.parse(url).query)["state"]

    assert {:ok, authorized} =
             OAuthJobs.complete(session, %{
               "state" => state,
               "code" => "accepted"
             })

    before = directory()
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [])

    response = submit(conn, %{"operation" => "cancel_sign_in"})
    assert redirected_to(response, 303) == "/connections/github?github=authorized"
    assert Auth.status(Actions.digest(session)) == %{status: :connected}
    assert directory() == before
    assert Enum.any?(before.connections, &(&1.id == authorized.connection.id))
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  test "discovery updates installations using only the selected account's credential", c do
    first = authorize(c.session)
    second = authorize_other(c.session)
    other = organization("ORG_OTHER")
    tokens = TestGitHub.state().tokens
    added = TestGitHub.owner(%{github_id: "ORG_NEW", login: "new-owner", installation_id: 4})

    TestGitHub.configure(
      calls: [],
      installation_sets: %{
        "github_access_fake" => [TestGitHub.owner(%{login: "renamed"}), added]
      }
    )

    response =
      submit(c.conn, %{"operation" => "discover", "connection_id" => first.connection.id})

    assert redirected_to(response, 303) == "/connections/github?github=discovery_queued"
    assert TestGitHub.state().calls == []
    assert {:ok, _} = GitHubDiscovery.finish(first.connection.id)
    assert organization("ORG_ACME").login == "renamed"
    assert organization("ORG_NEW").connection_id == first.connection.id
    assert organization("USER_SYNTHETIC").status == :reauthorization
    assert organization("ORG_OTHER") == other
    assert connection(second.connection.id).status == :ready
    assert TestGitHub.state().tokens == tokens

    assert TestGitHub.state().calls == [
             {:user, "github_access_fake"},
             {:installations, "github_access_fake"}
           ]
  end

  for reason <- [:rate_limited, :provider, :unavailable, :configuration, :denied] do
    test "discovery reports #{reason} honestly without changing credentials", c do
      authorized = authorize(c.session)
      before = directory()
      tokens = TestGitHub.state().tokens
      reason = unquote(reason)
      TestGitHub.configure(calls: [], installation_response: {:error, reason})

      response =
        submit(c.conn, %{"operation" => "discover", "connection_id" => authorized.connection.id})

      assert redirected_to(response, 303) == "/connections/github?github=discovery_queued"
      assert TestGitHub.state().calls == []
      assert {:error, ^reason} = GitHubDiscovery.finish(authorized.connection.id)
      assert connection(authorized.connection.id).discovery_error == reason

      assert TestGitHub.state().tokens == tokens

      assert TestGitHub.state().calls == [
               {:user, "github_access_fake"},
               {:installations, "github_access_fake"}
             ]

      if unquote(reason == :denied) do
        assert connection(authorized.connection.id).status == :reauthorization
        assert Enum.all?(directory().organizations, &(&1.status == :reauthorization))
      else
        assert Map.take(directory(), [:organizations, :memberships]) ==
                 Map.take(before, [:organizations, :memberships])

        assert connection(authorized.connection.id).status == :ready
      end
    end
  end

  test "discovery requiring reconnection fences the account and reports access failure", c do
    authorized = authorize(c.session)
    workspace = workspace("Reconnection")
    org = organization("ORG_ACME")
    GitHub.attach!(workspace.id, org.id, actor: @owner)
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [], user_response: {:error, :reconnect})

    response =
      submit(c.conn, %{"operation" => "discover", "connection_id" => authorized.connection.id})

    assert redirected_to(response, 303) == "/connections/github?github=discovery_queued"
    assert TestGitHub.state().calls == []
    assert {:error, :reconnect} = GitHubDiscovery.finish(authorized.connection.id)
    assert connection(authorized.connection.id).status == :reauthorization
    assert organization("ORG_ACME").status == :reauthorization
    assert [%{workspace_id: id}] = directory().memberships
    assert id == workspace.id
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == [{:user, "github_access_fake"}]
  end

  test "unavailable keychain during discovery cannot call the provider with another credential",
       c do
    authorized = authorize(c.session)
    other = authorize_other(c.session)
    before_other = connection(other.connection.id)
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [], keychain_error: :locked)

    response =
      submit(c.conn, %{"operation" => "discover", "connection_id" => authorized.connection.id})

    assert redirected_to(response, 303) == "/connections/github?github=keychain_failed"
    assert connection(other.connection.id) == before_other
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  test "attach, repository selection and detach change only the requested workspace membership",
       c do
    authorize(c.session)
    org = organization("ORG_ACME")
    first = workspace("First selection")
    second = workspace("Second selection")
    GitHub.attach!(second.id, org.id, actor: @owner)
    GitHub.poll!(org.id, org.generation, actor: @owner)
    other_membership = Enum.find(directory().memberships, &(&1.workspace_id == second.id))
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [])
    params = %{"workspace_id" => first.id, "organization_id" => org.id}

    response = submit(c.conn, Map.put(params, "operation", "attach"))
    assert redirected_to(response, 303) == "/workspaces/#{first.id}?github=attached"
    membership = Enum.find(directory().memberships, &(&1.workspace_id == first.id))
    assert membership.organization_id == org.id
    assert membership.repository_ids == []

    response =
      submit(
        c.conn,
        Map.merge(params, %{
          "operation" => "attach_repositories",
          "repository_ids" => ["REPO_SYNTHETIC", "REPO_SYNTHETIC"]
        })
      )

    assert redirected_to(response, 303) == "/workspaces/#{first.id}?github=attached"
    selected = Enum.find(directory().memberships, &(&1.workspace_id == first.id))
    assert selected.id == membership.id
    assert selected.repository_ids == ["REPO_SYNTHETIC"]
    assert Enum.find(directory().memberships, &(&1.workspace_id == second.id)) == other_membership

    response = submit(c.conn, Map.put(params, "operation", "detach"))
    assert redirected_to(response, 303) == "/workspaces/#{first.id}?github=detached"
    assert directory().memberships == [other_membership]
    assert organization("ORG_ACME").status == :ready
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  test "unknown repository selection cannot replace a valid selection or attach all repositories",
       c do
    authorize(c.session)
    org = organization("ORG_ACME")
    workspace = workspace("Validated selection")
    GitHub.poll!(org.id, org.generation, actor: @owner)
    GitHub.attach_repositories!(workspace.id, org.id, ["REPO_SYNTHETIC"], actor: @owner)
    before = directory()
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [])

    response =
      submit(c.conn, %{
        "operation" => "attach_repositories",
        "workspace_id" => workspace.id,
        "organization_id" => org.id,
        "repository_ids" => ["REPO_SYNTHETIC", "OTHER_ACCOUNT_REPO"]
      })

    assert redirected_to(response, 303) == "/workspaces/#{workspace.id}?github=unavailable"
    assert directory() == before
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  test "disconnecting an organization removes its memberships but retains shared account access",
       c do
    authorized = authorize(c.session)
    workspace = workspace("Disconnect owner")
    org = organization("ORG_ACME")
    personal = organization("USER_SYNTHETIC")
    GitHub.attach!(workspace.id, org.id, actor: @owner)
    GitHub.attach!(workspace.id, personal.id, actor: @owner)
    GitHub.poll!(org.id, org.generation, actor: @owner)
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [])

    response = submit(c.conn, %{"operation" => "disconnect", "organization_id" => org.id})
    assert redirected_to(response, 303) == "/connections/github?github=disconnected"
    disconnected = organization("ORG_ACME")
    assert disconnected.status == :disconnected
    assert disconnected.pull_requests == []
    assert disconnected.repositories == []
    assert disconnected.fetched_at == nil
    assert disconnected.generation != org.generation
    assert organization("USER_SYNTHETIC").status == :ready
    assert [%{organization_id: remaining}] = directory().memberships
    assert remaining == personal.id
    assert connection(authorized.connection.id).status == :ready
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  test "account sign-out removes only its credential and memberships, leaving another account intact",
       c do
    first = authorize(c.session)
    second = authorize_other(c.session)
    workspace = workspace("Separate accounts")

    for org <- directory().organizations,
        do: GitHub.attach!(workspace.id, org.id, actor: @owner)

    other_org = organization("ORG_OTHER")
    other_account = connection(second.connection.id)
    other_membership = Enum.find(directory().memberships, &(&1.organization_id == other_org.id))
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [])

    response =
      submit(c.conn, %{
        "operation" => "disconnect_account",
        "connection_id" => first.connection.id
      })

    assert redirected_to(response, 303) == "/connections/github?github=signed_out"
    assert connection(first.connection.id).status == :disconnected

    assert directory().organizations
           |> Enum.filter(&(&1.connection_id == first.connection.id))
           |> Enum.all?(&(&1.status == :disconnected))

    assert organization("ORG_OTHER") == other_org
    assert connection(second.connection.id) == other_account
    assert directory().memberships == [other_membership]
    assert TestGitHub.state().tokens == Map.delete(tokens, first.connection.id)
    assert TestGitHub.state().calls == []
  end

  test "failed account credential deletion reports keychain failure and can be retried", c do
    authorized = authorize(c.session)
    org = organization("ORG_ACME")
    workspace = workspace("Deletion failure")
    GitHub.attach!(workspace.id, org.id, actor: @owner)
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [], keychain_delete_error: :locked)
    params = %{"operation" => "disconnect_account", "connection_id" => authorized.connection.id}

    response = submit(c.conn, params)
    assert redirected_to(response, 303) == "/connections/github?github=keychain_failed"
    assert connection(authorized.connection.id).status == :disconnected
    assert connection(authorized.connection.id).last_error == :keychain
    assert organization("ORG_ACME").status == :disconnected
    assert directory().memberships == []
    assert TestGitHub.state().tokens == tokens

    assert {:error, :reconnect} =
             Credentials.access_token(authorized.connection.id)

    TestGitHub.configure(keychain_delete_error: nil)
    response = submit(c.conn, params)
    assert redirected_to(response, 303) == "/connections/github?github=signed_out"
    assert connection(authorized.connection.id).last_error == nil
    assert TestGitHub.state().tokens == Map.delete(tokens, authorized.connection.id)
    assert TestGitHub.state().calls == []
  end

  test "malformed identifiers redirect safely without changing existing connection state", c do
    authorized = authorize(c.session)
    org = organization("ORG_ACME")
    workspace = workspace("Identifier validation")
    GitHub.attach!(workspace.id, org.id, actor: @owner)
    before = directory()
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [])

    for params <- [
          %{"operation" => "discover", "connection_id" => "not-a-uuid"},
          %{"operation" => "disconnect_account", "connection_id" => "not-a-uuid"},
          %{"operation" => "disconnect", "organization_id" => "not-a-uuid"},
          %{
            "operation" => "attach",
            "organization_id" => org.id,
            "workspace_id" => "https://attacker.example/"
          }
        ] do
      response = submit(c.conn, params)
      assert redirected_to(response, 303) == "/connections/github?github=invalid_input"
    end

    for operation <- ["attach", "attach_repositories", "detach"] do
      response =
        submit(c.conn, %{
          "operation" => operation,
          "organization_id" => "not-a-uuid",
          "workspace_id" => workspace.id,
          "repository_ids" => ["REPO_SYNTHETIC"]
        })

      assert redirected_to(response, 303) == "/workspaces/#{workspace.id}?github=invalid_input"
    end

    assert connection(authorized.connection.id).status == :ready
    assert directory() == before
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  test "invalid field shapes and missing client fields cannot mutate settings or memberships",
       c do
    authorize(c.session)
    org = organization("ORG_ACME")
    workspace = workspace("Malformed fields")
    before = directory()
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [])

    for fields <- [
          %{},
          %{"client_id" => ["Iv1.attacker"], "client_secret" => "secret", "app_slug" => "app"},
          %{"client_id" => "Iv1.attacker", "client_secret" => %{"nested" => "secret"}}
        ] do
      response = submit(c.conn, Map.put(fields, "operation", "save_client"))
      assert redirected_to(response, 303) == "/connections/github?github=invalid_settings"
    end

    for selection <- ["REPO_SYNTHETIC", %{"id" => "REPO_SYNTHETIC"}] do
      response =
        submit(c.conn, %{
          "operation" => "attach_repositories",
          "organization_id" => org.id,
          "workspace_id" => workspace.id,
          "repository_ids" => selection
        })

      assert redirected_to(response, 303) == "/workspaces/#{workspace.id}?github=invalid_input"
    end

    assert directory() == before
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  test "invalid form encodings and content types are rejected before provider or storage access",
       c do
    before = directory()
    tokens = TestGitHub.state().tokens

    for {headers, body} <- [
          {[], "operation=sign_in"},
          {[{"content-type", "application/json"}], ~s({"operation":"sign_in"})},
          {[{"content-type", "application/x-www-form-urlencoded"}], "operation=%FF"}
        ] do
      request =
        Plug.Test.conn(:post, "/connections/github", body)
        |> init_test_session(%{owner_session_token: c.session})
        |> put_private(:plug_skip_csrf_protection, true)

      response =
        Enum.reduce(headers, request, fn {key, value}, conn ->
          put_req_header(conn, key, value)
        end)
        |> GitHubCredentials.call([])

      assert response.status == 400
      assert response.halted
      assert response.params == %{}
      assert response.body_params == %{}
      assert response.query_string == ""
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end

    assert directory() == before
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  test "revoked owner sessions cannot mutate GitHub connections or expose pending authorization",
       c do
    authorized = authorize(c.session)
    org = organization("ORG_ACME")
    workspace = workspace("Owner boundary")
    GitHub.attach!(workspace.id, org.id, actor: @owner)
    assert {:ok, _} = Auth.begin(c.session)
    Monolith.Owner.logout(c.session)
    before = directory()
    tokens = TestGitHub.state().tokens
    TestGitHub.configure(calls: [])

    for operation <- [
          "cancel_sign_in",
          "discover",
          "disconnect_account",
          "attach",
          "attach_repositories",
          "detach",
          "disconnect",
          "save_client"
        ] do
      response =
        submit(c.conn, %{
          "operation" => operation,
          "connection_id" => authorized.connection.id,
          "organization_id" => org.id,
          "workspace_id" => workspace.id,
          "repository_ids" => ["REPO_SYNTHETIC"],
          "client_id" => "Iv1.attacker",
          "client_secret" => "private_attacker_secret",
          "app_slug" => "attacker"
        })

      assert redirected_to(response, 303) == "/unlock"
      assert response.params == %{}
      assert response.body_params == %{}
    end

    assert Auth.status(Actions.digest(c.session)) == %{status: :idle}
    assert directory() == before
    assert TestGitHub.state().tokens == tokens
    assert TestGitHub.state().calls == []
  end

  defp directory, do: GitHub.directory!(actor: @owner)
  defp organization(id), do: Enum.find(directory().organizations, &(&1.github_id == id))
  defp connection(id), do: Enum.find(directory().connections, &(&1.id == id))
  defp workspace(name), do: Monolith.Workspaces.create_workspace!(name, actor: @owner)

  defp authorize(session, token \\ "github_access_fake") do
    assert {:ok, authorized} = Operations.authorize(session, TestGitHub.bundle(token))
    authorized
  end

  defp authorize_other(session) do
    TestGitHub.configure(
      identities: %{"other_access" => %{github_id: "USER_OTHER", login: "other"}},
      installation_sets: %{
        "other_access" => [
          TestGitHub.owner(%{github_id: "ORG_OTHER", login: "other", installation_id: 3})
        ]
      }
    )

    authorize(session, "other_access")
  end

  defp issue_session do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Monolith.Owner.issue_session!(
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
