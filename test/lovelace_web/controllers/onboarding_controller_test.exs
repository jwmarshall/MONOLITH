defmodule LovelaceWeb.OnboardingControllerTest do
  use LovelaceWeb.ConnCase, async: false
  import ExUnit.CaptureLog

  alias Lovelace.Integrations.Google
  alias Lovelace.Integrations.Google.ClientCredentials
  alias Lovelace.{Mail, Onboarding}
  alias Lovelace.TestSupport.{OnboardingGoogleTransport, OnboardingKeychain}

  @owner [actor: %{role: :local_owner}]
  @id "synthetic-onboarding-client"
  @secret "synthetic-onboarding-secret"
  @redirect "http://localhost:4000/oauth/google/callback"

  setup %{conn: conn} do
    start_supervised!(OnboardingKeychain)
    {:ok, _} = Lovelace.TestMail.start()

    settings = [
      google_client_keychain: OnboardingKeychain,
      google_client_credentials: ClientCredentials,
      gmail_provider: Google,
      gmail_vault: Lovelace.TestMailVault,
      gmail: [redirect_uri: @redirect, transport: OnboardingGoogleTransport]
    ]

    previous = Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:lovelace, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:lovelace, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lovelace, key, value)
        {key, :error} -> Application.delete_env(:lovelace, key)
      end)
    end)

    %{conn: authenticate_owner(conn)}
  end

  test "every page is owner guarded, no-store and static; Back and reload preserve guide progress",
       %{conn: conn} do
    for path <- ["/onboarding" | Enum.map(Onboarding.steps(), &Onboarding.path/1)] do
      assert redirected_to(get(build_conn(:get, "http://localhost/"), path)) == "/unlock"
    end

    assert redirected_to(get(conn, "/onboarding")) == "/onboarding/project"
    assert {:ok, nil} = Onboarding.progress(@owner)
    response = post(conn, "/onboarding/project", %{operation: "continue"})
    assert redirected_to(response) == "/onboarding/authentication"
    assert Onboarding.entry_path() == "/onboarding/authentication"

    for step <- Onboarding.steps() do
      response = get(conn, Onboarding.path(step))
      html = html_response(response, 200)
      assert html =~ "onboarding-heading"
      assert html =~ "stage-static"
      refute html =~ "data-phx-main"
      refute html =~ "WorkspaceIdle"
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
      assert OnboardingKeychain.calls() == []
    end

    assert Onboarding.entry_path() == "/onboarding/authentication"
    assert html_response(get(conn, "/onboarding/audience"), 200) =~ "seven days"
    assert html_response(get(conn, "/onboarding/audience"), 200) =~ "In production"
    assert html_response(get(conn, "/onboarding/audience"), 200) =~ "does not verify"
    assert response(get(conn, "/onboarding/not-a-step"), 404) == "Setup page not found"
  end

  test "console links explicitly open a safe new tab and credential fields are ordinary private forms",
       %{conn: conn} do
    for step <- [:project, :authentication, :audience, :client] do
      page = get(conn, Onboarding.path(step)) |> html_response(200) |> LazyHTML.from_document()

      links = LazyHTML.query(page, "a[href^='https://']")
      targets = LazyHTML.attribute(links, "target")
      assert targets != []
      assert Enum.all?(targets, &(&1 == "_blank"))
      assert Enum.all?(LazyHTML.attribute(links, "rel"), &(&1 == "noopener noreferrer"))
    end

    page = get(conn, "/onboarding/client") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(LazyHTML.query(page, "#google-setup-credentials"), "action") == [
             "/onboarding/credentials"
           ]

    assert LazyHTML.attribute(LazyHTML.query(page, "#google-setup-credentials"), "method") == [
             "post"
           ]

    for field <- ["google-client-id", "google-client-secret"] do
      input = LazyHTML.query(page, "##{field}")
      assert LazyHTML.attribute(input, "type") == ["password"]
      assert LazyHTML.attribute(input, "autocomplete") == ["off"]
      assert LazyHTML.attribute(input, "value") == []
      assert LazyHTML.attribute(input, "phx-change") == []
    end
  end

  test "credentials are saved without request telemetry, logging, response/session echo or provider calls",
       %{conn: conn} do
    observer = self()
    handler = "google-setup-private-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:phoenix, :endpoint, :start], [:phoenix, :router_dispatch, :start]],
      fn event, _, metadata, _ -> send(observer, {:instrumented, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert capture_log(fn ->
             saved = submit(conn, %{client_id: @id, client_secret: @secret})
             assert redirected_to(saved, 303) == "/onboarding/connect"
             assert saved.params == %{}
             assert saved.body_params == %{}
             assert saved.query_params == %{}
             assert get_resp_header(saved, "cache-control") == ["no-store"]
             refute inspect(get_session(saved)) =~ @secret
             refute inspect(get_session(saved)) =~ @id
             refute saved.resp_body =~ @secret
             assert {:ok, %{client_id: @id, client_secret: @secret}} = ClientCredentials.read()
             assert {:ok, %{step: :connect}} = Onboarding.progress(@owner)
           end) == ""

    refute_receive {:instrumented, _, _}
    assert OnboardingKeychain.writes() == 1
    assert OnboardingKeychain.calls() == []
  end

  test "CSRF and active owner are both required before credentials can be saved", %{conn: conn} do
    page = conn |> put_private(:plug_skip_csrf_protection, false) |> get("/onboarding/client")

    [csrf] =
      page
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#google-setup-credentials input[name=_csrf_token]")
      |> LazyHTML.attribute("value")

    for token <- [nil, "invalid"] do
      refused =
        page
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> submit(%{client_id: @id, client_secret: @secret, _csrf_token: token})

      assert refused.status == 403
      assert refused.body_params == %{}
      assert OnboardingKeychain.writes() == 0
    end

    saved =
      page
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> submit(%{client_id: @id, client_secret: @secret, _csrf_token: csrf})

    assert redirected_to(saved, 303) == "/onboarding/connect"
    Lovelace.Owner.logout(get_session(saved, :owner_session_token))

    refused =
      saved
      |> recycle()
      |> submit(%{client_id: "another-synthetic-client", client_secret: @secret})

    assert redirected_to(refused, 303) == "/unlock"
    assert OnboardingKeychain.writes() == 1
  end

  test "credential route aliases, queries, malformed bodies and methods cannot enter telemetry",
       %{conn: conn} do
    observer = self()
    handler = "google-setup-aliases-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:phoenix, :endpoint, :start], [:phoenix, :router_dispatch, :start]],
      fn _, _, _, _ -> send(observer, :instrumented) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for path <- [
          "/onboarding/credentials/",
          "/onboarding/%63redentials",
          "/onboarding//credentials"
        ] do
      saved =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post(path, URI.encode_query(%{client_id: @id, client_secret: @secret}))

      assert redirected_to(saved, 303) == "/onboarding/connect"
    end

    for {method, path, body, status} <- [
          {:post, "/onboarding/credentials?client_secret=synthetic-query-secret", "", 400},
          {:get, "/onboarding/credentials?client_secret=synthetic-query-secret", "", 400},
          {:put, "/onboarding/credentials", "", 400},
          {:post, "/onboarding/credentials", String.duplicate("x", 66_000), 400},
          {:post, "/onboarding/credentials",
           "client_id[nested]=synthetic&client_secret=synthetic", 303}
        ] do
      refused =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> request(method, path, body)

      assert refused.status == status
      assert refused.params == %{}
      assert refused.body_params == %{}
      assert refused.query_string == ""
      refute refused.resp_body =~ "synthetic"
    end

    refute_receive :instrumented
  end

  test "failure is sanitized, input is never repopulated and progress does not advance", %{
    conn: conn
  } do
    Onboarding.start(@owner)
    OnboardingKeychain.fail("synthetic private native diagnostic")
    failed = submit(conn, %{client_id: @id, client_secret: @secret})
    assert redirected_to(failed, 303) == "/onboarding/client?notice=save_failed"
    html = get(conn, redirected_to(failed, 303)) |> html_response(200)
    assert html =~ "role=\"alert\""
    refute html =~ @id
    refute html =~ @secret
    refute html =~ "synthetic private native diagnostic"
    assert {:ok, %{step: :project, credentials_saved: false}} = Onboarding.progress(@owner)
  end

  test "connect submits actual production read-only OAuth with explicit Personal destination; callback remains authoritative",
       %{conn: conn} do
    saved = submit(conn, %{client_id: @id, client_secret: @secret})

    page =
      get(recycle(saved), "/onboarding/connect") |> html_response(200) |> LazyHTML.from_document()

    form = LazyHTML.query(page, "#onboarding-google-connect")
    assert LazyHTML.attribute(form, "action") == ["/oauth/google/start"]

    assert LazyHTML.attribute(LazyHTML.query(form, "input[name=workspace_id]"), "value") == [
             Onboarding.personal_workspace_id()
           ]

    assert LazyHTML.attribute(LazyHTML.query(form, "input[name=capability]"), "value") == [
             "gmail"
           ]

    assert OnboardingKeychain.calls() == []

    started =
      post(conn, "/oauth/google/start", %{
        workspace_id: Onboarding.personal_workspace_id(),
        capability: "gmail"
      })

    uri = started |> redirected_to(303) |> URI.parse()
    assert uri.host == "accounts.google.com"
    params = URI.decode_query(uri.query)
    assert params["client_id"] == @id
    assert params["scope"] == "openid email https://www.googleapis.com/auth/gmail.readonly"
    assert params["access_type"] == "offline"
    assert params["code_challenge_method"] == "S256"
    refute Map.has_key?(params, "client_secret")
    assert OnboardingKeychain.calls() == []

    callback =
      get(
        conn,
        "/oauth/google/callback?" <>
          URI.encode_query(%{code: "synthetic-code", state: params["state"]})
      )

    assert redirected_to(callback, 303) ==
             "/workspaces/#{Onboarding.personal_workspace_id()}?gmail=connected"

    assert OnboardingKeychain.calls() == [:exchange, :identity]
    assert {:ok, %{status: :ready, last_success_at: nil}} = Onboarding.connection(@owner)

    html = get(conn, "/onboarding/complete") |> html_response(200)
    assert html =~ "Google authorization has been saved"
    assert html =~ "first successful Gmail read has not yet been confirmed"
    assert html =~ "does not retry provider work" or html =~ "not a fresh check"
    assert OnboardingKeychain.calls() == [:exchange, :identity]
  end

  test "skip and completion never claim a Gmail connection or first read", %{conn: conn} do
    skipped = post(conn, "/onboarding/connect", %{operation: "continue"})
    assert redirected_to(skipped) == "/onboarding/complete"
    html = get(conn, "/onboarding/complete") |> html_response(200)
    assert html =~ "Gmail is not connected"
    refute html =~ "Google authorization has been saved"
    assert Mail.list_accounts!(@owner) == []
    assert redirected_to(post(conn, "/onboarding/complete", %{operation: "finish"})) == "/"
    refute Onboarding.pending?()
    assert html_response(get(conn, "/onboarding/complete"), 200) =~ "Gmail is not connected"
    assert OnboardingKeychain.calls() == []
  end

  defp submit(conn, params) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/onboarding/credentials", URI.encode_query(params))
  end

  defp request(conn, :get, path, _body), do: get(conn, path)
  defp request(conn, :put, path, body), do: put(conn, path, body)
  defp request(conn, :post, path, body), do: post(conn, path, body)
end
