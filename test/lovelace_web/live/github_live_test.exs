defmodule LovelaceWeb.GitHubLiveTest do
  use LovelaceWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Lovelace.{GitHub, TestGitHub, Workspaces}
  alias Lovelace.GitHub.Operations

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
