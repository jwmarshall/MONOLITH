defmodule MonolithWeb.GitHubLiveTest do
  use MonolithWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Monolith.TestSupport.BackgroundWork, only: [complete: 1]

  alias Monolith.{GitHub, TestGitHub, Workspaces}
  alias Monolith.GitHub.{Auth, Operations}
  alias Monolith.Owner.Actions
  alias Monolith.TestSupport.{GitHubDiscovery, OAuthJobs}

  @owner %{role: :local_owner}

  setup %{conn: conn} do
    start_supervised!({TestGitHub, []})
    keys = [:github_provider, :github_keychain]
    previous = Map.new(keys, &{&1, Application.get_env(:monolith, &1)})
    Application.put_env(:monolith, :github_provider, TestGitHub)
    Application.put_env(:monolith, :github_keychain, Monolith.TestGitHubKeychain)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:monolith, key)
        {key, value} -> Application.put_env(:monolith, key, value)
      end)
    end)

    conn = authenticate_owner(conn)

    GitHub.save_client_credentials!(
      "Iv1.synthetic",
      "synthetic_client_secret",
      "monolith-synthetic",
      actor: @owner
    )

    %{
      conn: conn,
      workspace: Workspaces.create_workspace!("GitHub studio", actor: @owner),
      session: get_session(conn, :owner_session_token)
    }
  end

  test "queued account-access discovery stays observable after its requesting view exits",
       %{conn: conn, workspace: workspace, session: session} do
    org = connect_owner(workspace, session)
    assert {:ok, operation} = GitHub.discover(org.connection_id, actor: @owner)
    {:ok, view, _} = live(conn, "/connections/github")
    selector = "#github-discovery-status-#{org.connection_id}"

    assert has_element?(
             view,
             "#{selector}[data-state=pending][data-job-id='#{operation.job_id}']"
           )

    assert has_element?(view, "#github-discover-#{org.connection_id} button[disabled]")
    GenServer.stop(view.pid, :normal)

    assert {:ok, _} = GitHubDiscovery.finish(org.connection_id)
    {:ok, reopened, html} = live(conn, "/connections/github")

    assert has_element?(
             reopened,
             "#{selector}[data-state=succeeded][data-operation-id='#{operation.id}']",
             "Account access refreshed"
           )

    assert has_element?(reopened, "#github-discover-#{org.connection_id} button:not([disabled])")
    refute html =~ "synthetic_client_secret"
    refute html =~ TestGitHub.bundle().access_token
  end

  test "Home keeps owner summaries distinct, workspace details escape provider text, and detach preserves summaries",
       %{conn: conn, workspace: workspace, session: session} do
    hostile = ~s(<img src="https://remote.invalid/tracker">)
    TestGitHub.configure(rows: [TestGitHub.row(%{"title" => hostile, "checks" => "FAILURE"})])
    acme = connect_owner(workspace, session, "acme")

    TestGitHub.configure(
      rows: [
        TestGitHub.row(%{
          "title" => "Independent personal change",
          "repository" => "synthetic/repo",
          "url" => "https://github.com/synthetic/repo/pull/7",
          "is_draft" => true
        })
      ]
    )

    beta = connect_owner(workspace, session, "synthetic")

    {:ok, view, html} = live(conn, "/")

    assert has_element?(
             view,
             "#github-org-#{acme.id} .github-home-metric:first-child .github-home-attention",
             "1"
           )

    assert has_element?(
             view,
             "#github-org-#{beta.id} .github-home-metric:first-child .github-home-attention",
             "0"
           )

    refute has_element?(view, "#github-readouts .github-pr-title")
    refute has_element?(view, "#github-readouts button:not(.github-home-owner-toggle)")
    refute has_element?(view, "#github-readouts summary")

    for org <- [acme, beta] do
      assert has_element?(view, "#github-home-toggle-#{org.id}[aria-expanded='false']")
      assert has_element?(view, "#github-home-repositories-#{org.id}[hidden]")
    end

    refute has_element?(view, "#github-readouts img")
    refute html =~ TestGitHub.bundle().access_token
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ TestGitHub.bundle().refresh_token

    render_patch(view, "/workspaces/#{workspace.id}/github/#{acme.id}")
    assert has_element?(view, "#workspace-github-org-#{acme.id} .github-pr-title", hostile)
    refute has_element?(view, "#workspace-github-org-#{beta.id}")
    refute has_element?(view, "#github-owner-activity", "Independent personal change")
    refute has_element?(view, "#workspace-github-readouts img")
    render_patch(view, "/workspaces/#{workspace.id}/github/#{beta.id}")
    assert has_element?(view, "#workspace-github-org-#{beta.id}", "Independent personal change")
    assert has_element?(view, "#workspace-github-org-#{beta.id}", "Draft")
    refute has_element?(view, "#workspace-github-org-#{acme.id}")
    render_patch(view, "/")

    {:ok, _} = GitHub.detach(workspace.id, acme.id, actor: @owner)

    assert has_element?(
             view,
             "#github-org-#{acme.id} a[href='/connections/github']",
             "Add to workspace"
           )

    assert has_element?(view, "#github-org-#{acme.id} .github-home-number", "1")
    refute has_element?(view, "#github-org-#{acme.id} a[href^='/workspaces/']")

    {:ok, _} = GitHub.disconnect(acme.id, actor: @owner)
    refute has_element?(view, "#github-org-#{acme.id}")
    assert has_element?(view, "#github-org-#{beta.id} .github-home-number", "1")
  end

  test "refresh failure retains the observation and shows stale rather than an empty success", %{
    conn: conn,
    workspace: workspace,
    session: session
  } do
    org = connect_owner(workspace, session)
    {:ok, view, _} = live(conn, "/connections/github")
    complete(view)
    TestGitHub.configure(response: {:error, :rate_limited})

    view
    |> element("button[phx-click='github:refresh'][phx-value-id='#{org.id}']")
    |> render_click()

    assert has_element?(view, "[role=alert]", "GitHub refresh requested")
    GitHub.poll(org.id, org.generation, actor: @owner)
    render_patch(view, "/workspaces/#{workspace.id}")
    assert has_element?(view, "#workspace-github-#{org.id}", "GitHub rate limit")
    assert has_element?(view, "#workspace-github-#{org.id}", "Stale")
    render_patch(view, "/")
    assert has_element?(view, "#github-org-#{org.id} .github-home-number", "1")
    refute has_element?(view, "#github-org-#{org.id}", "No open pull requests")
  end

  test "incomplete positive counts never claim no open pull requests", %{
    conn: conn,
    workspace: workspace,
    session: session
  } do
    TestGitHub.configure(
      response:
        {:ok,
         %{
           pull_requests: [],
           total_count: 2,
           truncated: true,
           partial_reasons: ["search_incomplete"]
         }}
    )

    org = connect_owner(workspace, session)
    {:ok, view, _} = live(conn, "/")

    assert has_element?(
             view,
             "#github-org-#{org.id} .github-home-metric:first-child .github-home-total",
             "—"
           )

    assert has_element?(
             view,
             "#github-org-#{org.id} .github-home-metric:first-child .github-home-attention",
             "—"
           )

    refute has_element?(view, "#github-org-#{org.id}", "No open pull requests")
  end

  test "failed credential deletion stays visible for retry but not as a working connection", %{
    conn: conn,
    workspace: workspace,
    session: session
  } do
    org = connect_owner(workspace, session)
    [account] = GitHub.directory!(actor: @owner).connections
    TestGitHub.configure(keychain_error: :unavailable)
    assert {:error, _} = GitHub.disconnect_account(account.id, actor: @owner)
    {:ok, view, _} = live(conn, "/connections/github")
    assert has_element?(view, "#github-account-#{account.id}", "Credential removal failed")
    assert has_element?(view, "#github-sign-out-#{account.id} button", "Retry credential removal")
    refute has_element?(view, "#github-connection-#{org.id} [phx-click='github:refresh']")
    render_patch(view, "/")
    refute has_element?(view, "#github-org-#{org.id}")
    render_patch(view, "/workspaces/#{workspace.id}/integrations")
    refute has_element?(view, "#github-attach-form option[value='#{org.id}']")
    TestGitHub.configure(keychain_error: nil)
    assert {:ok, _} = GitHub.disconnect_account(account.id, actor: @owner)
    render_patch(view, "/connections/github")
    refute has_element?(view, "#github-account-#{account.id}")
  end

  test "GitHub deep links mount only the selected provider and workspace controls use local memberships",
       %{conn: conn, workspace: workspace, session: session} do
    org = connect_owner(workspace, session)
    {:ok, view, _} = live(conn, "/connections/github")
    assert has_element?(view, "#connections-github[aria-current=page]")
    assert has_element?(view, "#github-connection-#{org.id}", "acme")
    assert has_element?(view, "#github-account-status-#{org.connection_id}", "Connected")
    complete(view)
    assert has_element?(view, "#github-client-editor:not([open])")
    assert has_element?(view, "#github-app-setup:not([open])")

    {:ok, reopened, _} = live(conn, "/connections/github")
    complete(reopened)
    assert has_element?(reopened, "#github-account-status-#{org.connection_id}", "Connected")
    assert has_element?(reopened, "#github-client-editor:not([open])")
    refute has_element?(view, "#connections-panel, #calendar-connections, #gemini-connection")

    render_patch(view, "/workspaces/#{workspace.id}")
    assert has_element?(view, "#workspace-github-#{org.id}", "acme")
    other = Workspaces.create_workspace!("Other area", actor: @owner)
    render_patch(view, "/workspaces/#{other.id}/integrations")
    refute has_element?(view, "#workspace-github-#{org.id}")
    assert has_element?(view, "#github-attach-form option[value='#{org.id}']", "acme")
    assert has_element?(view, "#github-attach-editor-setup[open]")
    render_patch(view, "/workspaces/#{other.id}")
    assert has_element?(view, "#github-attach-editor:not([open])")
    render_patch(view, "/workspaces/#{other.id}/integrations")
    assert has_element?(view, "#github-attach-editor-setup[open]")
  end

  test "saved settings enable sign-in without returning the secret; keychain errors are not missing settings",
       %{conn: conn} do
    loading = conn |> get("/connections/github") |> html_response(200) |> LazyHTML.from_document()
    assert Enum.empty?(LazyHTML.query(loading, "#github-client-editor, #github-app-setup"))

    {:ok, view, _} = live(conn, "/connections/github")
    html = complete(view)
    assert has_element?(view, "#github-sign-in-form")
    assert has_element?(view, "#github-client-editor:not([open])")
    assert has_element?(view, "#github-app-setup:not([open])")
    assert has_element?(view, "#github-client-status")
    refute has_element?(view, "[id^=github-account-status-]")
    refute html =~ "synthetic_client_secret"
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "synthetic_client_secret"
    assert TestGitHub.state().calls == []

    for failure <- [:locked, :unavailable] do
      TestGitHub.configure(keychain_error: failure)
      render_patch(view, "/connections")
      render_patch(view, "/connections/github")
      complete(view)
      assert has_element?(view, "#github-authorization [role=alert]", "could not be read")
      refute has_element?(view, "#github-sign-in-form")
      refute has_element?(view, "#github-authorization [role=status]", "setup is required")
    end
  end

  test "failed OAuth authorization remains a usable recovery page after the authorization tick",
       %{conn: conn, session: session} do
    {:ok, view, _} = live(conn, "/connections/github")
    complete(view)
    {:ok, authorization_url} = Auth.begin(session)
    params = authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:error, _} =
             OAuthJobs.complete(session, %{
               "state" => params["state"],
               "error" => "access_denied"
             })

    send(view.pid, :github_auth_tick)
    render(view)
    assert has_element?(view, "#github-authorization-error")
    assert has_element?(view, "#github-sign-in-form")
    refute has_element?(view, "#github-browser-authorization")
  end

  test "a rejected GitHub return remains recovery rather than waiting after reload", %{
    conn: conn,
    session: session
  } do
    {:ok, _} = Auth.begin(session)
    returned = get(conn, "/auth/github/callback?code=private_unlinked_code")

    for _ <- 1..2 do
      {:ok, view, _} = live(recycle(returned), "/connections/github")
      complete(view)
      send(view.pid, :github_auth_tick)
      html = render(view)
      assert has_element?(view, "#github-authorization-error")
      assert has_element?(view, "#github-sign-in-form")
      refute has_element?(view, "#github-browser-authorization")
      refute has_element?(view, "[id^=github-account-status-]")
      refute html =~ "private_unlinked_code"
    end

    assert Auth.status(Actions.digest(session)) == %{status: :pending}
    assert TestGitHub.state().calls == []
  end

  test "repository access discovery makes an existing connected account attachable without signing in again",
       %{conn: conn, workspace: workspace, session: session} do
    {:ok, view, _} = live(conn, "/workspaces/#{workspace.id}/integrations")
    assert has_element?(view, "#github-workspace-connect")
    refute has_element?(view, "#github-attach-form")

    TestGitHub.configure(installation_response: {:ok, []})
    {:ok, authorized} = Operations.authorize(session, TestGitHub.bundle())
    render(view)
    assert has_element?(view, "#github-workspace-connect")
    refute has_element?(view, "#github-attach-form")

    TestGitHub.configure(installation_response: :ok)
    assert {:ok, _} = GitHubDiscovery.discover(authorized.connection.id)
    render(view)
    assert has_element?(view, "#github-attach-form option")
    refute has_element?(view, "#github-workspace-connect")
    refute Enum.any?(TestGitHub.state().calls, &match?({:exchange_code, _, _, _, _, _}, &1))
  end

  test "workspace repository selections isolate pull requests, issues and Actions without hiding Home owners",
       %{conn: conn, workspace: workspace, session: session} do
    repositories = [
      %{"id" => "REPO_FIRST", "name" => "first", "full_name" => "acme/first"},
      %{"id" => "REPO_SECOND", "name" => "second", "full_name" => "acme/second"}
    ]

    rows =
      for {repo, number} <- Enum.with_index(repositories, 1) do
        TestGitHub.row(%{
          "repository_id" => repo["id"],
          "repository" => repo["full_name"],
          "title" => "Change in #{repo["name"]}",
          "number" => number,
          "url" => "https://github.com/#{repo["full_name"]}/pull/#{number}"
        })
      end

    issues =
      for {repo, number} <- Enum.with_index(repositories, 1) do
        %{
          "repository_id" => repo["id"],
          "repository" => repo["full_name"],
          "title" => "Issue in #{repo["name"]}",
          "number" => number,
          "author" => nil,
          "updated_at" => "2026-11-04T01:00:00Z",
          "url" => "https://github.com/#{repo["full_name"]}/issues/#{number}"
        }
      end

    runs =
      for {repo, number} <- Enum.with_index(repositories, 1) do
        %{
          "id" => number,
          "repository_id" => repo["id"],
          "repository" => repo["full_name"],
          "name" => "Build #{repo["name"]}",
          "status" => "completed",
          "conclusion" => "failure",
          "updated_at" => "2026-11-04T01:00:00Z",
          "url" => "https://github.com/#{repo["full_name"]}/actions/runs/#{number}"
        }
      end

    TestGitHub.configure(
      response:
        {:ok,
         %{
           repositories: repositories,
           pull_requests: rows,
           total_count: 2,
           truncated: false,
           issues: issues,
           issue_count: 2,
           issues_truncated: false,
           workflow_runs: runs,
           actions_truncated: false,
           partial_reasons: []
         }}
    )

    org = connect_owner(workspace, session)
    other = Workspaces.create_workspace!("Other repository", actor: @owner)
    GitHub.attach_repositories!(workspace.id, org.id, ["REPO_FIRST"], actor: @owner)
    GitHub.attach_repositories!(other.id, org.id, ["REPO_SECOND"], actor: @owner)

    {:ok, view, _} = live(conn, "/workspaces/#{workspace.id}")

    assert has_element?(
             view,
             "#github-repository-form-#{org.id} input[value='REPO_FIRST'][checked]"
           )

    refute has_element?(
             view,
             "#github-repository-form-#{org.id} input[value='REPO_SECOND'][checked]"
           )

    render_patch(view, "/workspaces/#{workspace.id}/github/#{org.id}")
    assert has_element?(view, "#workspace-github-readouts", "Change in first")
    assert has_element?(view, "#workspace-github-readouts", "Issue in first")
    assert has_element?(view, "#workspace-github-readouts", "Build first")
    assert has_element?(view, "#workspace-github-readouts", "Author unavailable")
    refute has_element?(view, "#workspace-github-readouts", "Deleted user")
    assert has_element?(view, "#workspace-github-readouts", "Failed")
    refute has_element?(view, "#workspace-github-readouts", "Change in second")
    refute has_element?(view, "#workspace-github-readouts", "Issue in second")
    refute has_element?(view, "#workspace-github-readouts", "Build second")
    refute has_element?(view, "#workspace-github-readouts", "2 open in accessible repositories")

    render_patch(view, "/workspaces/#{other.id}/github/#{org.id}")
    assert has_element?(view, "#workspace-github-readouts", "Issue in second")
    refute has_element?(view, "#workspace-github-readouts", "Issue in first")

    render_patch(view, "/")

    for repository <- repositories do
      row = "#github-org-#{org.id} [data-repository-id='#{repository["id"]}']"
      assert has_element?(view, "#{row} .github-home-repository-name", repository["full_name"])
      assert has_element?(view, "#{row} .github-home-metric:first-child .github-home-total", "1")
    end

    header_total =
      "#github-org-#{org.id} .github-home-owner-heading .github-home-metric:first-child .github-home-total"

    assert has_element?(view, header_total, "2")
    GitHub.attach_repositories!(other.id, org.id, ["REPO_FIRST"], actor: @owner)
    render(view)
    assert has_element?(view, header_total, "1")
    refute has_element?(view, "#github-org-#{org.id} [data-repository-id='REPO_SECOND']")
    GitHub.attach_repositories!(other.id, org.id, ["REPO_SECOND"], actor: @owner)
    render(view)
    assert has_element?(view, header_total, "2")

    refute has_element?(view, "#github-org-#{org.id} .github-pr-list")
    destination = "/workspaces/#{workspace.id}/github/#{org.id}"
    refute has_element?(view, "#github-org-#{org.id} .github-home-workspaces a")
    render_patch(view, "/workspaces/#{workspace.id}")

    view
    |> element("#workspace-github a[href='#{destination}']")
    |> render_click()

    assert_patch(view, destination)
    assert has_element?(view, "#workspace-github-readouts", "Change in first")
    refute has_element?(view, "#workspace-github-readouts", "Change in second")

    GitHub.attach!(workspace.id, org.id, actor: @owner)
    render_patch(view, "/workspaces/#{workspace.id}/github/#{org.id}")
    assert has_element?(view, "#workspace-github-readouts", "Issue in second")
    render_patch(view, "/workspaces/#{workspace.id}")
    assert has_element?(view, "#workspace-github-#{org.id}", "Whole owner")
  end

  test "workspace activity returns through its visible link and restores both history destinations",
       %{conn: conn, workspace: workspace, session: session} do
    org = connect_owner(workspace, session)
    workspace_path = "/workspaces/#{workspace.id}"
    activity_path = workspace_path <> "/github/#{org.id}"
    {:ok, view, _} = live(conn, workspace_path)
    mail_generation = :sys.get_state(view.pid).socket.assigns.mail.generation
    provider_calls = TestGitHub.state().calls

    view
    |> element("#workspace-github-#{org.id} a[href='#{activity_path}']")
    |> render_click()

    assert_patch(view, activity_path)
    assert has_element?(view, "#github-activity-title", org.login)
    refute has_element?(view, "#workspace-landing")

    view
    |> element("#github-owner-activity a", "Back to workspace")
    |> render_click()

    assert_patch(view, workspace_path)
    assert has_element?(view, "#workspace-landing")
    assert has_element?(view, "#workspace-github-#{org.id}")
    refute has_element?(view, "#github-owner-activity")

    # History patches must restore the same surfaces without reopening the workspace.
    render_patch(view, activity_path)
    assert has_element?(view, "#github-activity-title", org.login)
    render_patch(view, workspace_path)
    assert has_element?(view, "#workspace-landing")
    refute has_element?(view, "#github-owner-activity")
    render_patch(view, activity_path)
    assert has_element?(view, "#github-activity-title", org.login)
    refute has_element?(view, "#workspace-landing")
    assert :sys.get_state(view.pid).socket.assigns.mail.generation == mail_generation
    assert TestGitHub.state().calls == provider_calls
  end

  test "activity URLs reload one workspace owner without provider work and reject unrelated membership",
       %{conn: conn, workspace: workspace, session: session} do
    org = connect_owner(workspace, session)
    unrelated = Workspaces.create_workspace!("Unrelated owner view", actor: @owner)
    path = "/workspaces/#{workspace.id}/github/#{org.id}"
    provider_calls = TestGitHub.state().calls

    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#github-activity-title", org.login)
    assert has_element?(view, "a[href='/workspaces'][aria-current='page']")
    refute has_element?(view, "a[href='/'][aria-current='page']")
    assert has_element?(view, "#github-owner-activity a[href='/workspaces/#{workspace.id}']")
    assert has_element?(view, "#workspace-github-org-#{org.id} time", "UTC")
    assert TestGitHub.state().calls == provider_calls

    render_patch(view, "/")
    render_patch(view, path)
    assert has_element?(view, "#github-activity-title", org.login)
    assert TestGitHub.state().calls == provider_calls

    render_patch(view, "/workspaces/#{unrelated.id}/github/#{org.id}")
    refute has_element?(view, "#github-owner-activity")
    refute has_element?(view, "#workspace-github-org-#{org.id}")
    assert TestGitHub.state().calls == provider_calls
  end

  test "detaching open activity replaces its URL but preserves the owner in another workspace",
       %{conn: conn, workspace: workspace, session: session} do
    TestGitHub.configure(rows: [TestGitHub.row(%{"title" => "Acme retained change"})])
    acme = connect_owner(workspace, session)

    TestGitHub.configure(
      rows: [
        TestGitHub.row(%{
          "title" => "Personal retained change",
          "repository" => "synthetic/repo",
          "url" => "https://github.com/synthetic/repo/pull/7"
        })
      ]
    )

    personal = connect_owner(workspace, session, "synthetic")
    other = Workspaces.create_workspace!("Retained GitHub membership", actor: @owner)
    GitHub.attach!(other.id, acme.id, actor: @owner)
    activity_path = "/workspaces/#{workspace.id}/github/#{acme.id}"
    retained_path = "/workspaces/#{other.id}/github/#{acme.id}"
    personal_path = "/workspaces/#{workspace.id}/github/#{personal.id}"
    provider_calls = TestGitHub.state().calls
    {:ok, view, _} = live(conn, activity_path)
    assert has_element?(view, "#workspace-github-org-#{acme.id}", "Acme retained change")

    assert {:ok, _} = GitHub.detach(workspace.id, acme.id, actor: @owner)
    render(view)
    %{proxy: {ref, topic, _}} = view
    assert_receive {^ref, {:patch, ^topic, %{to: "/workspaces", kind: :replace}}}
    assert has_element?(view, "#workspace-list")
    refute has_element?(view, "#github-owner-activity, #workspace-github-readouts")
    refute has_element?(view, "main", "Acme retained change")

    render_patch(view, "/")
    assert has_element?(view, "#github-org-#{acme.id} .github-home-workspaces", other.name)
    refute has_element?(view, "#github-org-#{acme.id} .github-home-workspaces", workspace.name)

    assert has_element?(
             view,
             "#github-org-#{personal.id} .github-home-workspaces",
             workspace.name
           )

    refute has_element?(view, "#github-readouts .github-home-workspaces a")
    render_patch(view, "/workspaces/#{workspace.id}")
    refute has_element?(view, "#workspace-github-#{acme.id}")
    assert has_element?(view, "#workspace-github-#{personal.id}")

    render_patch(view, retained_path)
    assert has_element?(view, "#workspace-github-org-#{acme.id}", "Acme retained change")
    refute has_element?(view, "#workspace-github-org-#{personal.id}")
    render_patch(view, personal_path)
    assert has_element?(view, "#workspace-github-org-#{personal.id}", "Personal retained change")
    refute has_element?(view, "main", "Acme retained change")
    assert TestGitHub.state().calls == provider_calls
  end

  test "disconnecting open activity replaces its URL and removes that owner from every workspace",
       %{conn: conn, workspace: workspace, session: session} do
    TestGitHub.configure(rows: [TestGitHub.row(%{"title" => "Disconnected owner change"})])
    acme = connect_owner(workspace, session)

    TestGitHub.configure(
      rows: [
        TestGitHub.row(%{
          "title" => "Still connected personal change",
          "repository" => "synthetic/repo",
          "url" => "https://github.com/synthetic/repo/pull/7"
        })
      ]
    )

    personal = connect_owner(workspace, session, "synthetic")
    other = Workspaces.create_workspace!("Second GitHub membership", actor: @owner)
    GitHub.attach!(other.id, acme.id, actor: @owner)
    provider_calls = TestGitHub.state().calls
    {:ok, view, _} = live(conn, "/workspaces/#{workspace.id}/github/#{acme.id}")
    assert has_element?(view, "#workspace-github-org-#{acme.id}", "Disconnected owner change")

    assert {:ok, _} = GitHub.disconnect(acme.id, actor: @owner)
    render(view)
    %{proxy: {ref, topic, _}} = view
    assert_receive {^ref, {:patch, ^topic, %{to: "/workspaces", kind: :replace}}}
    assert has_element?(view, "#workspace-list")
    refute has_element?(view, "#github-owner-activity, #workspace-github-readouts")
    refute has_element?(view, "main", "Disconnected owner change")

    render_patch(view, "/")
    refute has_element?(view, "#github-org-#{acme.id}")
    assert has_element?(view, "#github-org-#{personal.id} .github-home-number", "1")
    render_patch(view, "/workspaces/#{other.id}")
    refute has_element?(view, "#workspace-github-#{acme.id}")
    refute has_element?(view, "#github-owner-activity")
    render_patch(view, "/workspaces/#{workspace.id}")
    refute has_element?(view, "#workspace-github-#{acme.id}")
    assert has_element?(view, "#workspace-github-#{personal.id}")

    render_patch(view, "/workspaces/#{workspace.id}/github/#{personal.id}")

    assert has_element?(
             view,
             "#workspace-github-org-#{personal.id}",
             "Still connected personal change"
           )

    refute has_element?(view, "main", "Disconnected owner change")
    assert TestGitHub.state().calls == provider_calls
  end

  test "late changes from a departed activity cannot replace another owner or reopen activity",
       %{conn: conn, workspace: workspace, session: session} do
    TestGitHub.configure(rows: [TestGitHub.row(%{"title" => "Departed owner change"})])
    acme = connect_owner(workspace, session)

    TestGitHub.configure(
      rows: [
        TestGitHub.row(%{
          "title" => "Current personal change",
          "repository" => "synthetic/repo",
          "url" => "https://github.com/synthetic/repo/pull/7"
        })
      ]
    )

    personal = connect_owner(workspace, session, "synthetic")
    provider_calls = TestGitHub.state().calls
    {:ok, view, _} = live(conn, "/workspaces/#{workspace.id}/github/#{acme.id}")
    personal_path = "/workspaces/#{workspace.id}/github/#{personal.id}"
    render_patch(view, personal_path)
    assert_patch(view, personal_path)

    assert {:ok, _} = GitHub.detach(workspace.id, acme.id, actor: @owner)
    render(view)
    refute_patched(view)
    assert has_element?(view, "#github-activity-title", personal.login)
    assert has_element?(view, "#workspace-github-org-#{personal.id}", "Current personal change")
    refute has_element?(view, "main", "Departed owner change")
    refute has_element?(view, "#workspace-github-org-#{acme.id}")

    render_patch(view, "/settings")
    assert_patch(view, "/settings")
    assert {:ok, _} = GitHub.disconnect(acme.id, actor: @owner)
    render(view)
    refute_patched(view)

    # An owner notification already in flight may arrive after its subscription is removed.
    send(view.pid, {:github_changed, acme.id})
    Phoenix.PubSub.broadcast(Monolith.PubSub, "github:directory", :github_directory_changed)
    render(view)
    refute_patched(view)
    assert has_element?(view, "#show-settings[aria-current=page]")
    assert has_element?(view, "#settings-panel")
    refute has_element?(view, "#github-owner-activity, #workspace-github-readouts")
    refute has_element?(view, "main", "Departed owner change")

    render_patch(view, personal_path)
    assert has_element?(view, "#workspace-github-org-#{personal.id}", "Current personal change")
    refute has_element?(view, "main", "Departed owner change")
    assert TestGitHub.state().calls == provider_calls
  end

  test "partial issue and Actions failures never become successful empty readouts",
       %{conn: conn, workspace: workspace, session: session} do
    TestGitHub.configure(
      response:
        {:ok,
         %{
           repositories: [],
           pull_requests: [],
           total_count: 0,
           truncated: false,
           issues: [],
           issue_count: nil,
           issues_truncated: true,
           workflow_runs: [],
           actions_truncated: true,
           partial_reasons: ["issues_unavailable", "actions_unavailable"]
         }}
    )

    org = connect_owner(workspace, session)
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#github-org-#{org.id} .github-home-number", "—")

    assert has_element?(
             view,
             "#github-org-#{org.id} .github-home-metric:last-child .github-home-total",
             "—"
           )

    refute has_element?(view, "#github-org-#{org.id}", "No open issues")
    refute has_element?(view, "#github-org-#{org.id}", "No recent workflow runs")
  end

  defp connect_owner(workspace, session, login \\ "acme") do
    if GitHub.directory!(actor: @owner).connections == [] do
      assert {:ok, _} = Operations.authorize(session, TestGitHub.bundle())
    end

    org = Enum.find(GitHub.directory!(actor: @owner).organizations, &(&1.login == login))
    GitHub.attach!(workspace.id, org.id, actor: @owner)
    GitHub.refresh!(org.id, actor: @owner)
    GitHub.poll!(org.id, org.generation, actor: @owner)
    Enum.find(GitHub.directory!(actor: @owner).organizations, &(&1.id == org.id))
  end
end
