defmodule MonolithWeb.OnboardingControllerTest do
  use MonolithWeb.ConnCase, async: false
  import ExUnit.CaptureLog

  alias Ash.Domain.Info, as: DomainInfo
  alias Ash.Resource.Info
  alias Monolith.Calendar.State
  alias Monolith.Google.Access
  alias Monolith.Integrations.Google
  alias Monolith.Integrations.Google.ClientCredentials
  alias Monolith.{Mail, Onboarding}
  alias Monolith.Mail.WorkspaceAccount
  alias Monolith.Onboarding.CalendarSetup
  alias Monolith.TestSupport.{OAuthJobs, OnboardingGoogleTransport, OnboardingKeychain}

  @owner [actor: %{role: :local_owner}]
  @id "synthetic-onboarding-client"
  @secret "synthetic-onboarding-secret"
  @redirect "http://localhost:4000/oauth/google/callback"

  setup %{conn: conn} = context do
    start_supervised!(OnboardingKeychain)
    {:ok, _} = Monolith.TestMail.start()

    settings = [
      google_client_keychain: OnboardingKeychain,
      google_client_credentials: ClientCredentials,
      gmail_provider: Google,
      calendar_provider: Monolith.Integrations.Google.Calendar,
      gmail_vault: Monolith.TestMailVault,
      gmail: [redirect_uri: @redirect, transport: OnboardingGoogleTransport]
    ]

    previous = Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:monolith, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:monolith, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:monolith, key, value)
        {key, :error} -> Application.delete_env(:monolith, key)
      end)
    end)

    workspace =
      unless context[:fresh_onboarding] do
        {:ok, _} = Onboarding.save_workspace("Research", @owner)
        {:ok, workspace} = Onboarding.workspace(@owner)
        workspace
      end

    %{conn: authenticate_owner(conn), workspace: workspace}
  end

  @tag :fresh_onboarding
  test "every page is owner guarded, no-store and static; Back and reload preserve guide progress",
       %{conn: conn} do
    for path <- ["/onboarding" | Enum.map(Onboarding.steps(), &Onboarding.path/1)] do
      assert redirected_to(get(build_conn(:get, "http://localhost/"), path)) == "/unlock"
    end

    assert redirected_to(get(conn, "/onboarding")) == "/onboarding/workspace"
    assert {:ok, nil} = Onboarding.progress(@owner)
    assert redirected_to(get(conn, "/onboarding/project")) == "/onboarding/workspace"
    assert Monolith.Workspaces.list_workspaces!(@owner) == []

    invalid =
      conn
      |> post("/onboarding/workspace", %{operation: "save_workspace", name: "  "})
      |> html_response(422)

    assert invalid =~ "role=\"alert\""

    saved =
      post(conn, "/onboarding/workspace", %{operation: "save_workspace", name: "  Studio  "})

    assert redirected_to(saved) == "/onboarding/project"
    assert {:ok, workspace} = Onboarding.workspace(@owner)
    assert workspace.name == "Studio"
    assert [%{id: id}] = Monolith.Workspaces.list_workspaces!(@owner)
    assert id == workspace.id

    renamed =
      post(conn, "/onboarding/workspace", %{operation: "save_workspace", name: "Research"})

    assert redirected_to(renamed) == "/onboarding/project"
    assert [%{id: ^id, name: "Research"}] = Monolith.Workspaces.list_workspaces!(@owner)
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
    Monolith.Owner.logout(get_session(saved, :owner_session_token))

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

  test "connect uses the chosen workspace and Calendar selection remains inside the guide",
       %{conn: conn, workspace: workspace} do
    saved = submit(conn, %{client_id: @id, client_secret: @secret})

    page =
      get(recycle(saved), "/onboarding/connect") |> html_response(200) |> LazyHTML.from_document()

    form = LazyHTML.query(page, "#onboarding-google-connect")
    assert LazyHTML.attribute(form, "action") == ["/oauth/google/start"]

    assert LazyHTML.attribute(LazyHTML.query(form, "input[name=workspace_id]"), "value") == [
             workspace.id
           ]

    assert LazyHTML.attribute(LazyHTML.query(form, "input[name=capability]"), "value") == [
             "gmail"
           ]

    assert OnboardingKeychain.calls() == []

    form_params = form_params(form)

    started = post(conn, "/oauth/google/start", form_params)

    ordinary =
      post(conn, "/oauth/google/start", %{workspace_id: workspace.id})

    ordinary_params =
      ordinary |> redirected_to(303) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

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
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <>
          URI.encode_query(%{code: "synthetic-code", state: params["state"]})
      )

    assert redirected_to(callback, 303) == "/onboarding/calendar"
    assert Onboarding.entry_path() == "/onboarding/calendar"
    assert Onboarding.pending?()

    assert OnboardingKeychain.calls() == [:exchange, :identity]

    assert {:ok, %{id: account_id, calendar_enabled: false, status: :ready}} =
             Onboarding.connection(@owner)

    calendar_page =
      get(conn, redirected_to(callback, 303)) |> html_response(200) |> LazyHTML.from_document()

    calendar_form = LazyHTML.query(calendar_page, "#onboarding-calendar-connect")
    calendar_started = post(conn, "/oauth/google/start", form_params(calendar_form))

    calendar_params =
      calendar_started
      |> redirected_to(303)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert calendar_params["scope"] ==
             "openid email https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events.readonly"

    assert {:ok, %{calendar_enabled: false}} = Onboarding.connection(@owner)

    calendar_callback =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <>
          URI.encode_query(%{code: "synthetic-calendar-code", state: calendar_params["state"]})
      )

    assert redirected_to(calendar_callback, 303) == "/onboarding/calendar"
    assert Onboarding.entry_path() == "/onboarding/calendar"
    assert Onboarding.pending?()

    assert {:ok, %{id: ^account_id, generation: calendar_generation, calendar_enabled: true}} =
             Onboarding.connection(@owner)

    assert [%{id: ^account_id}] = Mail.list_accounts!(@owner)
    assert OnboardingKeychain.calls() == [:exchange, :identity, :exchange, :identity]

    stale_callback =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <>
          URI.encode_query(%{code: "synthetic-code", state: ordinary_params["state"]})
      )

    assert redirected_to(stale_callback, 303) ==
             "/connections/gmail?reason=reconnect&gmail=failed&stage=connection"

    assert {:ok,
            %{
              id: ^account_id,
              generation: ^calendar_generation,
              calendar_enabled: true,
              status: :ready
            }} = Onboarding.connection(@owner)

    assert Onboarding.entry_path() == "/onboarding/calendar"
    assert Onboarding.pending?()
    assert [%{id: ^account_id}] = Mail.list_accounts!(@owner)

    for callback_context <- [
          %{},
          %{origin: "onboarding", return_to: "https://untrusted.example/"}
        ] do
      fresh = post(conn, "/oauth/google/start", %{workspace_id: workspace.id})

      fresh_params =
        fresh |> redirected_to(303) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      ordinary_callback =
        OAuthJobs.get(
          conn,
          "/oauth/google/callback?" <>
            URI.encode_query(
              Map.merge(callback_context, %{code: "synthetic-code", state: fresh_params["state"]})
            )
        )

      assert redirected_to(ordinary_callback, 303) ==
               "/workspaces/#{workspace.id}?gmail=connected"

      assert {:ok, %{id: ^account_id, calendar_enabled: false, status: :ready}} =
               Onboarding.connection(@owner)

      assert [%{id: ^account_id}] = Mail.list_accounts!(@owner)
      assert Onboarding.entry_path() == "/onboarding/calendar"
      assert Onboarding.pending?()
    end
  end

  for request_kind <- [:page, :status, :rejected_selection] do
    @tag render_request: request_kind
    test "Calendar full-page #{request_kind} render cannot mix a detached account with the current picker",
         %{conn: conn, workspace: workspace, render_request: request_kind} do
      [{account_a, membership_a}, {account_b, _membership_b}] =
        Enum.map(
          [{"a", ~U[2020-01-01 00:00:00Z]}, {"b", ~U[2020-01-02 00:00:00Z]}],
          fn {suffix, attached_at} ->
            account =
              Mail.save_connection!(
                %{
                  subject: "calendar-render-#{suffix}",
                  email: "calendar-render-#{suffix}@example.invalid",
                  generation: Ash.UUID.generate(),
                  calendar_enabled: true
                },
                @owner
              )

            membership =
              WorkspaceAccount
              |> Ash.Changeset.for_create(
                :attach,
                %{workspace_id: workspace.id, account_id: account.id},
                @owner
              )
              |> Ash.Changeset.force_change_attribute(:created_at, attached_at)
              |> Ash.create!()

            {account, membership}
          end
        )

      now = DateTime.utc_now()
      calendar_id = "account-b-calendar@example.invalid"
      calendar_name = "Account B private calendar"

      State
      |> Ash.Changeset.for_create(
        :store,
        %{
          account_id: account_b.id,
          generation: account_b.generation,
          revision: Ash.UUID.generate(),
          calendars: [%{id: calendar_id, name: calendar_name}],
          selected_ids: [calendar_id],
          explicit_selection: true,
          from_at: now,
          to_at: DateTime.add(now, 86_400, :second),
          local_date: DateTime.to_date(now),
          timezone: "Etc/UTC",
          context_at: now,
          catalog_at: now,
          next_poll_at: now
        },
        @owner
      )
      |> Ash.create!()

      assert {:ok, %{id: current_id}} = Onboarding.connection(@owner)
      assert current_id == account_a.id

      observer = self()
      interleaving = make_ref()
      handler = "calendar-full-page-interleaving-#{System.unique_integer([:positive])}"
      event = [:ash, DomainInfo.short_name(Mail), :read, :stop]

      assert :ok =
               :telemetry.attach(
                 handler,
                 event,
                 fn _, _, metadata, _ ->
                   if self() == observer and
                        metadata[:resource] == WorkspaceAccount and
                        metadata[:action] == :read do
                     # The result already contains A. Detach before the controller's
                     # independent Calendar read, and detach the handler first so
                     # membership actions cannot recursively trigger it.
                     :telemetry.detach(handler)
                     result = Mail.detach_account(membership_a, @owner)
                     send(observer, {:calendar_render_detached, interleaving, result})
                   end
                 end,
                 nil
               )

      on_exit(fn -> :telemetry.detach(handler) end)

      response =
        case request_kind do
          :page ->
            get(conn, "/onboarding/calendar")

          :status ->
            get(conn, "/onboarding/calendar?status=1")

          :rejected_selection ->
            post(conn, "/onboarding/calendar", %{
              operation: "select_calendars",
              workspace_id: workspace.id,
              account_id: account_a.id,
              generation: account_a.generation,
              calendar_ids: "invalid-selection"
            })
        end

      assert_received {:calendar_render_detached, ^interleaving, :ok}
      status = if request_kind == :rejected_selection, do: 422, else: 200
      page = response |> html_response(status) |> LazyHTML.from_document()
      heading = page |> LazyHTML.query("#onboarding-calendar-status") |> LazyHTML.text()

      assert heading =~ account_a.email
      refute heading =~ account_b.email
      assert LazyHTML.text(page) =~ "Calendar selection is unavailable"
      refute LazyHTML.text(page) =~ calendar_name
      assert Enum.empty?(LazyHTML.query(page, "#onboarding-calendar-selection"))
      assert Enum.empty?(LazyHTML.query(page, "#onboarding-calendar-load"))
      assert Enum.empty?(LazyHTML.query(page, "[data-account-id='#{account_b.id}']"))
      assert Enum.empty?(LazyHTML.query(page, "input[value='#{calendar_id}']"))

      fresh = get(conn, "/onboarding/calendar") |> html_response(200) |> LazyHTML.from_document()
      fresh_heading = fresh |> LazyHTML.query("#onboarding-calendar-status") |> LazyHTML.text()
      picker = LazyHTML.query(fresh, "[data-onboarding-calendar]")

      assert fresh_heading =~ account_b.email
      refute fresh_heading =~ account_a.email
      assert LazyHTML.attribute(picker, "data-workspace-id") == [workspace.id]
      assert LazyHTML.attribute(picker, "data-account-id") == [account_b.id]
      assert LazyHTML.attribute(picker, "data-generation") == [account_b.generation]
      assert LazyHTML.text(fresh) =~ calendar_name

      selection =
        fresh
        |> LazyHTML.query("#onboarding-calendar-selection")
        |> form_params()

      assert selection["workspace_id"] == workspace.id
      assert selection["account_id"] == account_b.id
      assert selection["generation"] == account_b.generation

      assert LazyHTML.attribute(LazyHTML.query(fresh, "input[value='#{calendar_id}']"), "checked") ==
               [""]

      assert OnboardingKeychain.calls() == []
    end
  end

  test "calendar loading, shared selection, empty selection and stale forms stay in onboarding",
       %{conn: conn, workspace: workspace} do
    submit(conn, %{client_id: @id, client_secret: @secret})
    {:ok, _} = Onboarding.continue(:connect, @owner)

    {:ok, account} =
      Access.accept(
        workspace.id,
        %{subject: "synthetic-onboarding-subject", email: "synthetic@example.invalid"},
        "synthetic-refresh",
        :calendar
      )

    page = get(conn, "/onboarding/calendar") |> html_response(200) |> LazyHTML.from_document()
    load_params = form_params(LazyHTML.query(page, "#onboarding-calendar-load"))
    picker = LazyHTML.query(page, "[data-onboarding-calendar]")
    assert LazyHTML.attribute(picker, "data-workspace-id") == [workspace.id]
    assert LazyHTML.attribute(picker, "data-account-id") == [account.id]
    assert LazyHTML.attribute(picker, "data-generation") == [account.generation]

    assert LazyHTML.attribute(LazyHTML.query(page, "[data-calendar-progress]"), "data-autoload") ==
             ["true"]

    status_page =
      get(conn, "/onboarding/calendar?status=1") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(
             LazyHTML.query(status_page, "[data-calendar-progress]"),
             "data-autoload"
           ) == ["false"]

    assert LazyHTML.attribute(
             LazyHTML.query(status_page, "[data-calendar-progress]"),
             "data-status-only"
           ) == ["true"]

    assert {:ok, %{catalog_at: nil, loading: false}} = CalendarSetup.read(@owner)
    assert OnboardingKeychain.calls() == []

    date = Date.utc_today()

    window = %{
      "from" => DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601(),
      "to" => DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601(),
      "date" => Date.to_iso8601(date),
      "timezone" => "Etc/UTC"
    }

    assert redirected_to(post(conn, "/onboarding/calendar", Map.merge(load_params, window))) ==
             "/onboarding/calendar"

    assert OnboardingKeychain.calls() == []

    state =
      Monolith.Calendar.State
      |> Ash.Query.for_read(:read, %{account_id: account.id}, @owner)
      |> Ash.read_one!()

    Monolith.Calendar.poll!(account.id, account.generation, state.revision, @owner)

    current =
      Monolith.Calendar.State
      |> Ash.Query.for_read(:read, %{account_id: account.id}, @owner)
      |> Ash.read_one!()

    attributes =
      current
      |> Map.from_struct()
      |> Map.take(Info.action(Monolith.Calendar.State, :store).accept)
      |> Map.merge(%{truncated: true, selection_truncated: false})

    Monolith.Calendar.State
    |> Ash.Changeset.for_create(:store, attributes, @owner)
    |> Ash.create!()

    page = get(conn, "/onboarding/calendar") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.attribute(LazyHTML.query(page, "input[value=primary]"), "checked") == [""]

    assert LazyHTML.attribute(
             LazyHTML.query(page, "input[value='shared@example.invalid']"),
             "checked"
           ) == []

    assert LazyHTML.text(page) =~ "Calendar results are partial"
    refute LazyHTML.text(page) =~ "Not all Google-selected calendars"

    assert LazyHTML.attribute(LazyHTML.query(page, "[data-calendar-status]"), "href") ==
             ["/onboarding/calendar?status=1"]

    refresh_params =
      page |> LazyHTML.query("#onboarding-calendar-load") |> form_params() |> Map.merge(window)

    assert refresh_params["operation"] == "refresh_calendars"
    calls = OnboardingKeychain.calls()
    assert DateTime.compare(current.next_poll_at, DateTime.utc_now()) == :gt

    assert redirected_to(post(conn, "/onboarding/calendar", refresh_params)) ==
             "/onboarding/calendar"

    assert {:ok, %{loading: true}} = CalendarSetup.read(@owner)
    assert OnboardingKeychain.calls() == calls

    status_loading =
      get(conn, "/onboarding/calendar?status=1") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(
             LazyHTML.query(status_loading, "[data-calendar-progress]"),
             "data-status-only"
           ) == ["true"]

    assert OnboardingKeychain.calls() == calls

    selection =
      Map.merge(load_params, %{
        "operation" => "select_calendars",
        "calendar_ids" => ["", "shared@example.invalid"]
      })

    assert redirected_to(post(conn, "/onboarding/calendar", selection)) ==
             "/onboarding/calendar?notice=calendars_saved"

    assert {:ok, %{selected_ids: ["shared@example.invalid"]}} =
             CalendarSetup.read(@owner)

    assert Onboarding.entry_path() == "/onboarding/calendar"

    stale = Map.put(selection, "generation", Ash.UUID.generate())
    assert post(conn, "/onboarding/calendar", stale) |> html_response(422) =~ "role=\"alert\""

    assert {:ok, %{selected_ids: ["shared@example.invalid"]}} =
             CalendarSetup.read(@owner)

    assert redirected_to(
             post(conn, "/onboarding/calendar", Map.put(selection, "calendar_ids", [""]))
           ) ==
             "/onboarding/calendar?notice=calendars_saved"

    assert {:ok, %{selected_ids: []}} = CalendarSetup.read(@owner)

    assert redirected_to(post(conn, "/onboarding/calendar", %{operation: "continue"})) ==
             "/onboarding/complete"
  end

  @tag :fresh_onboarding
  test "first named workspace can skip all Google setup and explicitly finish without integrations",
       %{conn: conn} do
    for step <- [:project, :authentication, :audience, :client, :connect, :calendar] do
      assert redirected_to(post(conn, Onboarding.path(step), %{operation: "skip"})) ==
               "/onboarding/workspace"
    end

    assert redirected_to(post(conn, "/onboarding/complete", %{operation: "finish"})) ==
             "/onboarding/workspace"

    assert redirected_to(
             post(conn, "/onboarding/workspace", %{operation: "save_workspace", name: "Quiet"})
           ) == "/onboarding/project"

    for step <- [:project, :authentication, :audience, :client] do
      assert redirected_to(post(conn, Onboarding.path(step), %{operation: "skip"})) ==
               "/onboarding/complete"

      assert {:ok, %{finished: false, credentials_saved: false}} = Onboarding.progress(@owner)
    end

    review = get(conn, "/onboarding/complete") |> html_response(200)
    assert review =~ "href=\"/connections\""
    assert review =~ "href=\"/onboarding/project\""
    assert redirected_to(post(conn, "/onboarding/complete", %{operation: "finish"})) == "/"
    assert Onboarding.entry_path() == "/"
    assert {:ok, %{name: "Quiet"}} = Onboarding.workspace(@owner)
    assert Mail.list_accounts!(@owner) == []
    assert OnboardingKeychain.writes() == 0
    assert OnboardingKeychain.calls() == []
  end

  test "skip posts retain owner and CSRF protection", %{conn: conn} do
    assert redirected_to(
             post(build_conn(:get, "http://localhost/"), "/onboarding/project", %{
               operation: "skip"
             })
           ) == "/unlock"

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/onboarding/project", %{operation: "skip"})
    end

    assert {:ok, %{step: :project, finished: false}} = Onboarding.progress(@owner)
  end

  test "skipping Gmail and Calendar creates no connection and finishing ends only the guide", %{
    conn: conn
  } do
    skipped = post(conn, "/onboarding/connect", %{operation: "skip"})
    assert redirected_to(skipped) == "/onboarding/calendar"

    calendar_page =
      get(conn, redirected_to(skipped)) |> html_response(200) |> LazyHTML.from_document()

    assert Enum.empty?(LazyHTML.query(calendar_page, "#onboarding-calendar-connect"))
    reviewed = post(conn, "/onboarding/calendar", %{operation: "skip"})
    assert redirected_to(reviewed) == "/onboarding/complete"
    assert Mail.list_accounts!(@owner) == []
    assert redirected_to(post(conn, "/onboarding/complete", %{operation: "finish"})) == "/"
    refute Onboarding.pending?()
    assert OnboardingKeychain.calls() == []
  end

  test "skipping optional Calendar preserves Gmail and resumes at review", %{
    conn: conn,
    workspace: workspace
  } do
    submit(conn, %{client_id: @id, client_secret: @secret})

    {:ok, account} =
      Access.accept(
        workspace.id,
        %{subject: "synthetic-onboarding-subject", email: "synthetic@example.invalid"},
        "synthetic-refresh"
      )

    assert OnboardingKeychain.calls() == []

    assert redirected_to(post(conn, "/onboarding/calendar", %{operation: "skip"})) ==
             "/onboarding/complete"

    assert Onboarding.entry_path() == "/onboarding/complete"

    assert {:ok, %{id: id, calendar_enabled: false, status: :ready}} =
             Onboarding.connection(@owner)

    assert id == account.id
    assert OnboardingKeychain.calls() == []
  end

  defp form_params(form) do
    form
    |> LazyHTML.query("input")
    |> Enum.map(fn input ->
      {[name], [value]} = {LazyHTML.attribute(input, "name"), LazyHTML.attribute(input, "value")}
      {name, value}
    end)
    |> Map.new()
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
