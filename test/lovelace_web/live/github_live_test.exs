defmodule LovelaceWeb.GitHubLiveTest do
  use LovelaceWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Lovelace.{GitHub, TestGitHub, Workspaces}
  alias Lovelace.GitHub.{Auth, Operations}
  alias Lovelace.Owner.Actions

  @owner %{role: :local_owner}

  setup %{conn: conn} do
    start_supervised!({TestGitHub, []})
    keys = [:github_provider, :github_keychain]
    previous = Map.new(keys, &{&1, Application.get_env(:lovelace, &1)})
    Application.put_env(:lovelace, :github_provider, TestGitHub)
    Application.put_env(:lovelace, :github_keychain, Lovelace.TestGitHubKeychain)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lovelace, key)
        {key, value} -> Application.put_env(:lovelace, key, value)
      end)
    end)

    conn = authenticate_owner(conn)

    GitHub.save_client_credentials!(
      "Iv1.synthetic",
      "synthetic_client_secret",
      "lovelace-synthetic",
      actor: @owner
    )

    %{
      conn: conn,
      workspace: Workspaces.create_workspace!("GitHub studio", actor: @owner),
      session: get_session(conn, :owner_session_token)
    }
  end

  test "Home keeps organizations distinct, escapes provider text and preserves readouts after workspace detach",
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
    assert has_element?(view, "#github-org-#{acme.id} .github-pr-title", hostile)
    assert has_element?(view, "#github-org-#{acme.id}", "Checks failing")
    assert has_element?(view, "#github-org-#{beta.id}", "Independent personal change")
    assert has_element?(view, "#github-org-#{beta.id}", "Draft")
    refute has_element?(view, "#github-org-#{acme.id}", "Independent personal change")
    refute has_element?(view, "#github-readouts img")
    refute html =~ TestGitHub.bundle().access_token
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ TestGitHub.bundle().refresh_token

    {:ok, _} = GitHub.detach(workspace.id, acme.id, actor: @owner)
    assert has_element?(view, "#github-org-#{acme.id}", "Not attached to a workspace")
    assert has_element?(view, "#github-org-#{acme.id} .github-pr-title", hostile)

    {:ok, _} = GitHub.disconnect(acme.id, actor: @owner)
    refute has_element?(view, "#github-org-#{acme.id}")
    assert has_element?(view, "#github-org-#{beta.id}", "Independent personal change")
  end

  test "refresh failure retains the observation and shows stale rather than an empty success", %{
    conn: conn,
    workspace: workspace,
    session: session
  } do
    org = connect_owner(workspace, session)
    {:ok, view, _} = live(conn, "/")
    TestGitHub.configure(response: {:error, :rate_limited})
    {:ok, _} = GitHub.refresh(org.id, actor: @owner)
    GitHub.poll(org.id, org.generation, actor: @owner)
    assert has_element?(view, "#github-org-#{org.id}", "GitHub rate limit")
    assert has_element?(view, "#github-org-#{org.id}", "Stale")
    assert has_element?(view, "#github-org-#{org.id}", "Synthetic pull request")
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
    assert has_element?(view, "#github-org-#{org.id}", "2 open")
    assert has_element?(view, "#github-org-#{org.id}", "details are unavailable")
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
    render_async(view)
    assert has_element?(view, "#github-client-editor:not([open])")
    assert has_element?(view, "#github-app-setup:not([open])")

    {:ok, reopened, _} = live(conn, "/connections/github")
    render_async(reopened)
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
    html = render_async(view)
    assert has_element?(view, "#github-sign-in-form")
    assert has_element?(view, "#github-client-editor:not([open])")
    assert has_element?(view, "#github-app-setup:not([open])")
    assert has_element?(view, "#github-client-status")
    refute has_element?(view, "[id^=github-account-status-]")
    refute html =~ "synthetic_client_secret"
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "synthetic_client_secret"
    assert TestGitHub.state().calls == []

    TestGitHub.configure(keychain_error: :locked)
    render_patch(view, "/connections")
    render_patch(view, "/connections/github")
    render_async(view)
    assert has_element?(view, "#github-authorization [role=alert]", "could not be read")
    refute has_element?(view, "#github-sign-in-form")
    refute has_element?(view, "#github-authorization [role=status]", "setup is required")
  end

  test "failed OAuth authorization remains a usable recovery page after the authorization tick",
       %{conn: conn, session: session} do
    {:ok, view, _} = live(conn, "/connections/github")
    render_async(view)
    {:ok, authorization_url} = Auth.begin(session)
    params = authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:error, _} =
             Auth.complete(session, %{"state" => params["state"], "error" => "access_denied"})

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
      render_async(view)
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
    assert {:ok, _} = GitHub.discover(authorized.connection.id, actor: @owner)
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

    assert has_element?(
             view,
             "#github-repository-form-#{org.id} input[value='REPO_FIRST'][checked]"
           )

    refute has_element?(
             view,
             "#github-repository-form-#{org.id} input[value='REPO_SECOND'][checked]"
           )

    render_patch(view, "/workspaces/#{other.id}")
    assert has_element?(view, "#workspace-github-readouts", "Issue in second")
    refute has_element?(view, "#workspace-github-readouts", "Issue in first")

    render_patch(view, "/")
    assert has_element?(view, "#github-org-#{org.id}", "Change in first")
    assert has_element?(view, "#github-org-#{org.id}", "Change in second")
    assert has_element?(view, "#github-org-#{org.id}", "2 open in accessible repositories")

    GitHub.attach!(workspace.id, org.id, actor: @owner)
    render_patch(view, "/workspaces/#{workspace.id}")
    assert has_element?(view, "#workspace-github-readouts", "Issue in second")
    assert has_element?(view, "#workspace-github-#{org.id}", "Whole owner")
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
    assert has_element?(view, "#github-org-#{org.id}", "Issue details unavailable")
    assert has_element?(view, "#github-org-#{org.id}", "Workflow run details unavailable")
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
