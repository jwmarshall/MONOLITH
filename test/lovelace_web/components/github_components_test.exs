defmodule LovelaceWeb.GitHubComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias LovelaceWeb.GitHubComponents

  @now ~U[2026-11-05 12:00:00Z]

  test "Home distinguishes owner totals from attention counts in the bounded snapshot" do
    document =
      snapshot(%{
        total_count: 42,
        issue_count: 17,
        pull_requests: [
          Lovelace.TestGitHub.row(%{"checks" => "FAILURE"}),
          Lovelace.TestGitHub.row(%{"is_draft" => true, "checks" => "SUCCESS"})
        ],
        workflow_runs: [
          Lovelace.TestGitHub.workflow_run(%{"conclusion" => "startup_failure"}),
          Lovelace.TestGitHub.workflow_run(%{"conclusion" => "success"})
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
      now: @now
    )
    |> LazyHTML.from_fragment()
  end
end
