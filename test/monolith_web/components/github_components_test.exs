defmodule MonolithWeb.GitHubComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MonolithWeb.GitHubComponents

  @now ~U[2026-11-05 12:00:00Z]

  test "Home distinguishes owner totals from attention counts in the bounded snapshot" do
    document =
      snapshot(%{
        total_count: 42,
        issue_count: 17,
        pull_requests: [
          Monolith.TestGitHub.row(%{"checks" => "FAILURE"}),
          Monolith.TestGitHub.row(%{"is_draft" => true, "checks" => "SUCCESS"})
        ],
        workflow_runs: [
          Monolith.TestGitHub.workflow_run(%{"conclusion" => "startup_failure"}),
          Monolith.TestGitHub.workflow_run(%{"conclusion" => "success"})
        ]
      })

    assert LazyHTML.query(document, ".github-home-metric:nth-child(1) .github-home-total")
           |> LazyHTML.text() == "42"

    assert LazyHTML.query(document, ".github-home-metric:nth-child(1) .github-home-attention")
           |> LazyHTML.text() == "1"

    assert LazyHTML.query(document, ".github-home-metric:nth-child(2) .github-home-total")
           |> LazyHTML.text() == "17"

    assert LazyHTML.query(document, ".github-home-metric:nth-child(3) .github-home-total")
           |> LazyHTML.text() == "2"

    assert LazyHTML.query(document, ".github-home-metric:nth-child(3) .github-home-attention")
           |> LazyHTML.text() == "1"
  end

  test "unavailable results never become zero counts" do
    document =
      snapshot(%{
        total_count: nil,
        issue_count: nil,
        truncated: true,
        issues_truncated: true,
        actions_truncated: true
      })

    for index <- 1..3 do
      assert LazyHTML.query(
               document,
               ".github-home-metric:nth-child(#{index}) .github-home-total"
             )
             |> LazyHTML.text() == "—"
    end

    for index <- [1, 3] do
      assert LazyHTML.query(
               document,
               ".github-home-metric:nth-child(#{index}) .github-home-attention"
             )
             |> LazyHTML.text() == "—"
    end
  end

  test "unobserved and expired snapshots cannot present old counts as current" do
    for fetched_at <- [nil, DateTime.add(@now, -86_400)] do
      document = snapshot(%{fetched_at: fetched_at, total_count: 42, issue_count: 17})

      for index <- 1..3 do
        assert LazyHTML.query(
                 document,
                 ".github-home-metric:nth-child(#{index}) .github-home-total"
               )
               |> LazyHTML.text() == "—"
      end
    end
  end

  test "activity destinations include only the owner's attached workspaces" do
    document =
      snapshot(%{},
        memberships: [
          %{organization_id: "synthetic-owner", workspace_id: "studio"},
          %{organization_id: "synthetic-owner", workspace_id: "personal"},
          %{organization_id: "other-owner", workspace_id: "other"}
        ],
        workspace_options: [{"Studio", "studio"}, {"Personal", "personal"}, {"Other", "other"}]
      )

    links = LazyHTML.query(document, ".github-home-links a")

    assert LazyHTML.attribute(links, "href") == [
             "/workspaces/studio#workspace-github-org-synthetic-owner",
             "/workspaces/personal#workspace-github-org-synthetic-owner"
           ]

    assert LazyHTML.text(links) =~ "Studio"
    assert LazyHTML.text(links) =~ "Personal"
    assert Enum.empty?(LazyHTML.query(document, "button, details, .github-pr-list"))
  end

  test "unattached owners offer workspace setup rather than an unrelated activity destination" do
    document = snapshot(%{}, workspace_options: [{"Unrelated", "other"}])

    assert LazyHTML.query(document, ".github-home-links a") |> LazyHTML.attribute("href") ==
             ["/connections/github"]

    assert Enum.empty?(LazyHTML.query(document, "a[href^='/workspaces/']"))
  end

  test "workspace empty results distinguish confirmed absence from unavailable details" do
    complete = workspace_snapshot(%{})

    partial =
      workspace_snapshot(%{
        total_count: nil,
        issue_count: nil,
        truncated: true,
        issues_truncated: true,
        actions_truncated: true
      })

    assert LazyHTML.query(complete, ".github-summary") |> LazyHTML.text() =~
             "0 open in accessible repositories"

    assert LazyHTML.query(complete, ".mail-muted") |> LazyHTML.text() =~
             "No open pull requests found"

    assert LazyHTML.query(complete, ".github-related-activity .mail-muted") |> LazyHTML.text() =~
             "No open issues found"

    assert LazyHTML.query(complete, ".github-related-activity .mail-muted") |> LazyHTML.text() =~
             "No recent workflow runs found"

    assert Enum.empty?(LazyHTML.query(complete, ".connection-warning, .github-pr"))
    assert Enum.count(LazyHTML.query(partial, ".connection-warning")) == 3
    refute LazyHTML.query(partial, ".github-summary") |> LazyHTML.text() =~ "open in"
    refute LazyHTML.query(partial, ".mail-muted") |> LazyHTML.text() =~ "No open"
    refute LazyHTML.query(partial, ".mail-muted") |> LazyHTML.text() =~ "No recent"

    assert LazyHTML.query(partial, ".mail-muted") |> LazyHTML.text() =~
             "Pull request details are unavailable"

    assert LazyHTML.query(partial, ".github-related-activity .mail-muted") |> LazyHTML.text() =~
             "Issue details unavailable"

    assert LazyHTML.query(partial, ".github-related-activity .mail-muted") |> LazyHTML.text() =~
             "Workflow run details unavailable"
  end

  test "repository-scoped workspace snapshots never expose another selection or owner totals" do
    document =
      workspace_snapshot(
        %{
          total_count: 321,
          issue_count: 654,
          pull_requests: [
            Monolith.TestGitHub.row(),
            Monolith.TestGitHub.row(%{
              "repository_id" => "OTHER_REPO",
              "title" => "Private other pull request",
              "url" => "https://github.com/acme/private/pull/17"
            })
          ],
          issues: [
            Monolith.TestGitHub.issue(),
            Monolith.TestGitHub.issue(%{
              "repository_id" => "OTHER_REPO",
              "title" => "Private other issue"
            })
          ],
          workflow_runs: [
            Monolith.TestGitHub.workflow_run(),
            Monolith.TestGitHub.workflow_run(%{
              "repository_id" => "OTHER_REPO",
              "name" => "Private other workflow"
            })
          ]
        },
        memberships: [
          %{
            organization_id: "synthetic-owner",
            workspace_id: "studio",
            repository_ids: ["REPO_SYNTHETIC"]
          },
          %{
            organization_id: "synthetic-owner",
            workspace_id: "other-workspace",
            repository_ids: ["OTHER_REPO"]
          }
        ]
      )

    assert Enum.count(LazyHTML.query(document, ".github-pr")) == 3
    assert Enum.count(LazyHTML.query(document, ".connection-warning")) == 3
    assert LazyHTML.query(document, ".github-summary") |> LazyHTML.text() =~ "1 shown"
    refute LazyHTML.query(document, ".github-summary") |> LazyHTML.text() =~ "321"
    refute LazyHTML.query(document, ".github-summary") |> LazyHTML.text() =~ "654"
    refute LazyHTML.text(document) =~ "Private other"
    assert Enum.empty?(LazyHTML.query(document, "a[href*='/private/']"))
  end

  test "pull request reviews and checks remain distinct with safe missing metadata" do
    cases = [
      {%{"is_draft" => true, "checks" => "PENDING"}, "Draft", "Checks pending"},
      {%{"review_decision" => "APPROVED"}, "Approved", "Checks passing"},
      {%{"review_decision" => "CHANGES_REQUESTED", "checks" => "ERROR"}, "Changes requested",
       "Checks failing"},
      {%{"checks" => "FAILURE"}, "Awaiting review", "Checks failing"},
      {%{"review_decision" => nil, "checks" => nil}, "Review status unavailable",
       "Checks unavailable"}
    ]

    pull_requests =
      cases
      |> Enum.with_index(1)
      |> Enum.map(fn {{overrides, _, _}, number} ->
        Monolith.TestGitHub.row(
          Map.merge(overrides, %{
            "number" => number,
            "title" => "<script>PR #{number}</script>",
            "url" => "https://github.com/acme/repo/pull/#{number}",
            "author" => nil,
            "updated_at" =>
              case number do
                1 -> nil
                2 -> "invalid-date"
                _ -> "2026-11-04T03:00:00+02:00"
              end
          })
        )
      end)

    document = workspace_snapshot(%{pull_requests: pull_requests, total_count: 42})

    for {{_, review, checks}, index} <- Enum.with_index(cases, 1) do
      row =
        LazyHTML.query(
          document,
          ".github-pr:not(.github-issue):not(.github-workflow-run):nth-child(#{index})"
        )

      assert LazyHTML.query(row, ".github-pr-title") |> LazyHTML.attribute("href") ==
               ["https://github.com/acme/repo/pull/#{index}"]

      assert LazyHTML.query(row, ".github-pr-title") |> LazyHTML.text() =~
               "<script>PR #{index}</script>"

      assert LazyHTML.query(row, ".github-pr-title") |> LazyHTML.attribute("target") == ["_blank"]

      assert LazyHTML.query(row, ".github-pr-title") |> LazyHTML.attribute("rel") ==
               ["noopener noreferrer"]

      assert LazyHTML.query(row, ".github-pr-state > span:nth-child(1)")
             |> LazyHTML.text()
             |> String.trim() ==
               review

      assert LazyHTML.query(row, ".github-pr-state > span:nth-child(2)")
             |> LazyHTML.text()
             |> String.trim() ==
               checks

      assert LazyHTML.query(row, ".github-pr-meta") |> LazyHTML.text() =~ "Author unavailable"

      assert Enum.count(LazyHTML.query(row, ".github-check-failed")) ==
               if(checks == "Checks failing", do: 1, else: 0)

      assert LazyHTML.query(row, "time") |> LazyHTML.text() |> String.trim() ==
               if(index <= 2, do: "Updated time unavailable", else: "Updated Nov 04, 01:00 UTC")
    end

    assert Enum.empty?(LazyHTML.query(document, "script"))
    summary = LazyHTML.query(document, ".github-summary") |> LazyHTML.text()
    assert summary =~ "5 shown"
    assert summary =~ "42 open in accessible repositories"
    assert summary =~ "1 awaiting review"
    assert summary =~ "2 with failing checks"
    assert summary =~ "1 draft"
  end

  test "Actions distinguish terminal failures, running, waiting and unavailable outcomes" do
    cases = [
      {"completed", "timed_out", "Timed out", true},
      {"completed", "cancelled", "Cancelled", false},
      {"in_progress", nil, "In progress", false},
      {"waiting", nil, "Waiting", false},
      {"completed", "new-conclusion", "Conclusion unavailable", false},
      {"new-status", nil, "Status unavailable", false}
    ]

    runs =
      cases
      |> Enum.with_index(1)
      |> Enum.map(fn {{status, conclusion, _, _}, id} ->
        Monolith.TestGitHub.workflow_run(%{
          "id" => id,
          "name" => "Workflow #{id}",
          "url" => "https://github.com/acme/repo/actions/runs/#{id}",
          "status" => status,
          "conclusion" => conclusion
        })
      end)

    document = workspace_snapshot(%{workflow_runs: runs, actions_truncated: true})

    for {{_, _, label, failed?}, index} <- Enum.with_index(cases, 1) do
      row = LazyHTML.query(document, ".github-workflow-run:nth-child(#{index})")

      assert LazyHTML.query(row, ".github-pr-state > span")
             |> LazyHTML.text()
             |> String.trim() == label

      assert Enum.count(LazyHTML.query(row, ".github-check-failed")) ==
               if(failed?, do: 1, else: 0)

      assert LazyHTML.query(row, "a") |> LazyHTML.attribute("href") ==
               ["https://github.com/acme/repo/actions/runs/#{index}"]

      assert LazyHTML.query(row, "a") |> LazyHTML.attribute("rel") == ["noopener noreferrer"]
    end

    assert LazyHTML.query(document, ".github-related-activity .connection-warning")
           |> LazyHTML.text() =~ "Partial Actions"

    refute LazyHTML.query(document, ".github-related-activity .mail-muted")
           |> LazyHTML.text() =~ "No recent workflow runs"
  end

  test "pending authorization is cancellable while token exchange cannot start a second attempt" do
    pending = connections(auth: %{status: :pending})
    exchanging = connections(auth: %{status: :exchanging})

    assert LazyHTML.query(pending, "#github-browser-authorization[role='status']")
           |> LazyHTML.text() =~ "Not connected yet"

    assert LazyHTML.query(pending, "#github-sign-in-form button")
           |> LazyHTML.text()
           |> String.trim() ==
             "Start connection again"

    assert Enum.empty?(LazyHTML.query(exchanging, "#github-sign-in-form"))

    assert LazyHTML.query(exchanging, "#github-browser-authorization[role='status']")
           |> LazyHTML.text() =~ "Finishing connection"

    for document <- [pending, exchanging] do
      assert LazyHTML.query(document, "#github-cancel-sign-in") |> LazyHTML.attribute("action") ==
               ["/connections/github"]

      assert LazyHTML.query(document, "#github-cancel-sign-in input[name='operation']")
             |> LazyHTML.attribute("value") == ["cancel_sign_in"]
    end
  end

  test "keychain failure is not presented as revoked GitHub authorization or an available sign-in" do
    document = connections(configured: false, configuration_status: :unavailable)

    assert LazyHTML.query(document, "#github-authorization [role='alert']") |> LazyHTML.text() =~
             "not a GitHub authorization failure"

    assert Enum.empty?(LazyHTML.query(document, "#github-sign-in-form, #github-install-app"))

    assert LazyHTML.query(document, "#github-client-secret") |> LazyHTML.attribute("type") ==
             ["password"]

    assert LazyHTML.query(document, "#github-client-secret") |> LazyHTML.attribute("value") == []
  end

  test "failed authorization offers a fresh attempt without leaving an old browser attempt active" do
    document = connections(auth: %{status: :failed})

    assert LazyHTML.query(document, "#github-authorization-error[role='alert']")
           |> LazyHTML.text() =~ "No new account was connected"

    assert LazyHTML.query(document, "#github-sign-in-form button")
           |> LazyHTML.text()
           |> String.trim() ==
             "Start connection again"

    assert Enum.empty?(LazyHTML.query(document, "#github-browser-authorization"))
  end

  test "account recovery and discovery feedback stay attached to the matching account" do
    accounts = [
      account("queued", %{discovery_status: :pending}),
      account("running", %{discovery_status: :running}),
      account("finished", %{discovery_status: :succeeded}),
      account("failed", %{discovery_status: :failed, discovery_error: :reconnect}),
      account("replaced", %{discovery_status: :superseded, last_error: :unavailable}),
      account("reconnect", %{status: :reauthorization}),
      account("retained", %{status: :disconnected, last_error: :keychain}),
      account("removed", %{status: :disconnected})
    ]

    document = connections(connections: accounts)

    for {id, state, label} <- [
          {"queued", "pending", "queued"},
          {"running", "running", "Refreshing account access"},
          {"finished", "succeeded", "Account access refreshed"},
          {"failed", "failed", "could not be refreshed"},
          {"replaced", "superseded", "superseded"}
        ] do
      status = LazyHTML.query(document, "#github-account-#{id} #github-discovery-status-#{id}")
      assert LazyHTML.attribute(status, "data-state") == [state]
      assert LazyHTML.attribute(status, "data-operation-id") == ["operation-#{id}"]
      assert LazyHTML.attribute(status, "data-job-id") == ["job-#{id}"]
      assert LazyHTML.text(status) =~ label

      assert Enum.count(LazyHTML.query(document, "#github-discover-#{id} button[disabled]")) ==
               if(state in ["pending", "running"], do: 1, else: 0)

      assert LazyHTML.query(document, "#github-sign-out-#{id} input[name='connection_id']")
             |> LazyHTML.attribute("value") == [id]
    end

    assert LazyHTML.query(document, "#github-discovery-status-failed span") |> LazyHTML.text() =~
             "Sign in again"

    assert LazyHTML.query(document, "#github-account-replaced > .connection-warning")
           |> LazyHTML.text() =~ "Previously observed results may be stale"

    assert LazyHTML.query(document, "#github-account-reconnect .connection-warning")
           |> LazyHTML.text() =~ "Connect this account again"

    assert Enum.empty?(LazyHTML.query(document, "#github-discover-reconnect"))

    assert LazyHTML.query(document, "#github-account-retained [role='alert']")
           |> LazyHTML.text() =~ "Credential removal failed"

    assert LazyHTML.query(document, "#github-sign-out-retained button")
           |> LazyHTML.text()
           |> String.trim() ==
             "Retry credential removal"

    assert Enum.empty?(
             LazyHTML.query(document, "#github-discover-retained, #github-account-removed")
           )
  end

  test "keychain refresh failures retain dated observations only until their expiry" do
    cached =
      workspace_snapshot(%{
        last_error: :keychain,
        fetched_at: DateTime.add(@now, -600),
        total_count: 1,
        pull_requests: [Monolith.TestGitHub.row()],
        issues: [Monolith.TestGitHub.issue()],
        workflow_runs: [Monolith.TestGitHub.workflow_run()]
      })

    assert LazyHTML.query(cached, ".github-health[role='status'] .connection-warning")
           |> LazyHTML.text() =~ "Dedicated keychain unavailable"

    assert LazyHTML.query(cached, ".github-health .connection-warning")
           |> LazyHTML.text() =~ "Stale"

    assert LazyHTML.query(cached, ".github-health time") |> LazyHTML.attribute("datetime") ==
             ["2026-11-05T11:50:00Z"]

    assert Enum.count(LazyHTML.query(cached, ".github-pr")) == 3

    expired =
      workspace_snapshot(%{
        last_error: :keychain,
        fetched_at: DateTime.add(@now, -86_400),
        total_count: 1,
        pull_requests: [Monolith.TestGitHub.row()],
        issues: [Monolith.TestGitHub.issue()],
        workflow_runs: [Monolith.TestGitHub.workflow_run()]
      })

    assert LazyHTML.query(expired, ".github-health .connection-warning") |> LazyHTML.text() =~
             "Cached GitHub activity expired"

    assert Enum.empty?(
             LazyHTML.query(expired, ".github-pr, .github-summary, .github-related-activity")
           )
  end

  defp workspace_snapshot(overrides, options \\ []) do
    defaults = [
      workspace_id: "studio",
      memberships: [
        %{organization_id: "synthetic-owner", workspace_id: "studio", repository_ids: []}
      ]
    ]

    snapshot(overrides, Keyword.merge(defaults, options))
  end

  defp connections(options) do
    defaults = [
      organizations: [],
      connections: [],
      auth: %{status: :idle},
      configured: true,
      configuration_status: :ready,
      callback_url: "http://localhost:4000/connections/github/callback",
      memberships: [],
      workspace_options: [],
      error: false,
      now: @now
    ]

    render_component(&GitHubComponents.connections/1, Keyword.merge(defaults, options))
    |> LazyHTML.from_fragment()
  end

  defp account(id, overrides) do
    Map.merge(
      %{
        id: id,
        login: "synthetic-#{id}",
        status: :ready,
        last_error: nil,
        discovery_status: nil,
        discovery_id: "operation-#{id}",
        discovery_job_id: "job-#{id}",
        discovery_error: nil
      },
      overrides
    )
  end

  defp snapshot(overrides, options \\ []) do
    organization =
      Map.merge(
        %{
          id: "synthetic-owner",
          login: "acme",
          status: :ready,
          last_error: nil,
          fetched_at: @now,
          total_count: 0,
          issue_count: 0,
          pull_requests: [],
          issues: [],
          workflow_runs: [],
          truncated: false,
          issues_truncated: false,
          actions_truncated: false
        },
        overrides
      )

    render_component(&GitHubComponents.dashboard/1,
      organizations: [organization],
      memberships: Keyword.get(options, :memberships, []),
      workspace_options: Keyword.get(options, :workspace_options, []),
      error: false,
      workspace_id: Keyword.get(options, :workspace_id),
      now: @now
    )
    |> LazyHTML.from_fragment()
  end
end
