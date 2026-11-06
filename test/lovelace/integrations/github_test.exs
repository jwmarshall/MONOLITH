defmodule Lovelace.Integrations.GitHubTest.Transport do
  alias Lovelace.Integrations.GitHub.Transport

  def request(request, []) do
    :ok = Transport.validate(request)

    response =
      Agent.get_and_update(__MODULE__, fn state ->
        case state.responses do
          [response | rest] ->
            {response, %{state | responses: rest, requests: state.requests ++ [request]}}

          [] ->
            {{:error, :unexpected_request}, %{state | requests: state.requests ++ [request]}}
        end
      end)

    if is_function(response, 1), do: response.(request), else: response
  end
end

defmodule Lovelace.Integrations.GitHubTest do
  use ExUnit.Case, async: false
  import Kernel, except: [node: 0, node: 1]
  import ExUnit.CaptureLog
  @callback_uri "http://localhost:4321/auth/github/callback"
  alias Lovelace.Integrations.GitHub
  alias Lovelace.Integrations.GitHubTest.Transport

  setup do
    previous = Application.get_env(:lovelace, :github)
    Application.put_env(:lovelace, :github, transport: Transport)

    start_supervised!(%{
      id: Transport,
      start: {Agent, :start_link, [fn -> %{responses: [], requests: []} end, [name: Transport]]}
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lovelace, :github, previous),
        else: Application.delete_env(:lovelace, :github)
    end)

    :ok
  end

  defp response(body, status \\ 200, headers \\ []),
    do:
      {:ok,
       %{
         status: status,
         headers: headers,
         body: if(is_binary(body), do: body, else: Jason.encode!(body))
       }}

  defp enqueue(responses), do: Agent.update(Transport, &%{&1 | responses: responses})
  defp requests, do: Agent.get(Transport, & &1.requests)

  defp owner(type \\ :organization),
    do: %{installation_id: 123, github_id: "OWNER_SYNTHETIC", login: "Acme", owner_type: type}

  defp account(owner),
    do: %{
      "node_id" => owner.github_id,
      "login" => owner.login,
      "type" => if(owner.owner_type == :user, do: "User", else: "Organization")
    }

  defp graphql_owner(owner),
    do: %{
      "id" => owner.github_id,
      "login" => owner.login,
      "__typename" => if(owner.owner_type == :user, do: "User", else: "Organization")
    }

  defp installation(owner), do: %{"id" => owner.installation_id, "account" => account(owner)}

  defp installations(owners),
    do: %{"total_count" => length(owners), "installations" => Enum.map(owners, &installation/1)}

  defp repository(owner, index \\ 1),
    do: %{
      "id" => index,
      "node_id" => "REPO_#{index}",
      "name" => "example#{index}",
      "owner" => account(owner)
    }

  defp repositories(repos), do: %{"total_count" => length(repos), "repositories" => repos}

  defp node(overrides \\ %{}),
    do:
      Map.merge(
        %{
          "number" => 42,
          "title" => "Synthetic PR",
          "isDraft" => false,
          "reviewDecision" => "APPROVED",
          "updatedAt" => "2026-11-04T00:00:00Z",
          "createdAt" => "2026-11-03T00:00:00Z",
          "author" => %{"login" => "octocat"},
          "repository" => %{
            "id" => "REPO_1",
            "name" => "example1",
            "owner" => graphql_owner(owner())
          },
          "url" => "https://evil.invalid/private",
          "commits" => %{
            "nodes" => [%{"commit" => %{"statusCheckRollup" => %{"state" => "SUCCESS"}}}]
          }
        },
        overrides
      )

  defp graph_repo(owner, repo, nodes, count \\ nil, more \\ false),
    do: %{
      "id" => repo["node_id"],
      "name" => repo["name"],
      "owner" => graphql_owner(owner),
      "issues" => %{"totalCount" => 0, "nodes" => [], "pageInfo" => %{"hasNextPage" => false}},
      "pullRequests" => %{
        "totalCount" => count || length(nodes),
        "nodes" => nodes,
        "pageInfo" => %{"hasNextPage" => more}
      }
    }

  defp graph(nodes \\ [node()], count \\ nil, more \\ false),
    do: %{"data" => %{"r0" => graph_repo(owner(), repository(owner()), nodes, count, more)}}

  defp snapshot_responses(body, selected \\ owner(), repos \\ nil) do
    repos = repos || [repository(selected)]

    [
      response(installations([selected])),
      response(repositories(repos)),
      response(body)
    ] ++
      List.duplicate(
        response(%{"total_count" => 0, "workflow_runs" => []}),
        min(length(repos), 10)
      ) ++
      [response(installations([selected])), response(repositories(repos))]
  end

  defp token_bundle,
    do: %{
      "access_token" => "ghu_synthetic",
      "refresh_token" => "ghr_synthetic",
      "expires_in" => 28_800,
      "refresh_token_expires_in" => 15_897_600,
      "token_type" => "bearer",
      "scope" => ""
    }

  defp exchange(code \\ "synthetic_code", uri \\ @callback_uri) do
    GitHub.exchange_code(
      "Iv1.synthetic",
      "synthetic_secret",
      code,
      String.duplicate("v", 43),
      uri
    )
  end

  test "web exchange sends client secret PKCE and exact callback only in the private POST body" do
    enqueue([response(token_bundle())])
    assert {:ok, %{access_token: "ghu_synthetic"}} = exchange()
    [request] = requests()
    assert request.host == "github.com"
    assert request.path == "/login/oauth/access_token"

    assert URI.decode_query(request.body) == %{
             "client_id" => "Iv1.synthetic",
             "client_secret" => "synthetic_secret",
             "code" => "synthetic_code",
             "code_verifier" => String.duplicate("v", 43),
             "redirect_uri" => @callback_uri
           }

    refute List.keymember?(request.headers, "authorization", 0)
  end

  test "web exchange sanitizes provider failures without retrying" do
    for {body, expected} <- [
          {%{"error" => "access_denied"}, {:error, :denied}},
          {%{"error" => "bad_verification_code"}, {:error, :expired}},
          {%{"error" => "redirect_uri_mismatch"}, {:error, :configuration}},
          {%{"error" => "incorrect_client_credentials"}, {:error, :configuration}},
          {%{"error" => "unknown private detail", "error_description" => "synthetic_secret"},
           {:error, :provider}}
        ] do
      enqueue([response(body)])
      assert exchange() == expected
    end

    assert length(requests()) == 5
  end

  test "refresh sends stored client secret and accepts only expiring App token pairs" do
    enqueue([response(token_bundle())])

    assert {:ok, %{refresh_token: "ghr_synthetic"}} =
             GitHub.refresh_token("Iv1.synthetic", "synthetic_secret", "ghr_old")

    [refresh] = requests()

    assert URI.decode_query(refresh.body) == %{
             "client_id" => "Iv1.synthetic",
             "client_secret" => "synthetic_secret",
             "refresh_token" => "ghr_old",
             "grant_type" => "refresh_token"
           }

    refute List.keymember?(refresh.headers, "authorization", 0)

    for body <- [
          Map.delete(token_bundle(), "expires_in"),
          Map.delete(token_bundle(), "refresh_token"),
          Map.put(token_bundle(), "scope", "repo"),
          Map.put(token_bundle(), "access_token", "ghp_pat"),
          Map.put(token_bundle(), "refresh_token_expires_in", 0),
          Map.put(token_bundle(), "access_token", "ghu_header\r\n")
        ] do
      enqueue([response(body)])
      assert {:error, :provider} = exchange()
    end

    enqueue([response(%{"error" => "bad_refresh_token", "error_description" => "private"})])

    assert {:error, :reconnect} =
             GitHub.refresh_token("Iv1.synthetic", "synthetic_secret", "ghr_old")
  end

  test "exchange accepts the caller's approved localhost port without discovering Auth configuration" do
    callback = "http://localhost:54321/auth/github/callback"
    enqueue([response(token_bundle())])
    assert {:ok, %{access_token: "ghu_synthetic"}} = exchange("synthetic_code", callback)
    assert [%{body: body}] = requests()
    assert URI.decode_query(body)["redirect_uri"] == callback
  end

  test "invalid credentials callback or verifier never reach the transport" do
    assert {:error, :configuration} = exchange("bad\r\ncode")

    assert {:error, :configuration} =
             exchange("synthetic_code", "https://evil.invalid/auth/github/callback")

    assert {:error, :configuration} =
             GitHub.exchange_code(
               "Iv1.synthetic",
               "synthetic_secret",
               "synthetic_code",
               "short",
               @callback_uri
             )

    assert {:error, :reconnect} =
             GitHub.refresh_token("Iv1.synthetic", "synthetic_secret", "ghp_pat")

    assert requests() == []
  end

  test "user identity accepts only an immutable safe personal account identity" do
    enqueue([
      response(%{"id" => 99, "node_id" => "USER_1", "login" => "octocat", "type" => "User"})
    ])

    assert {:ok, %{github_id: "USER_1", login: "octocat"}} = GitHub.user("ghu_synthetic")
    assert List.last(requests()).path == "/user"

    for body <- [
          %{"id" => 99, "node_id" => "ORG", "login" => "Acme", "type" => "Organization"},
          %{"id" => 99, "node_id" => "USER", "login" => "../bad", "type" => "User"}
        ] do
      enqueue([response(body)])
      assert {:error, :provider} = GitHub.user("ghu_synthetic")
    end
  end

  test "installation discovery supports personal and multiple organization owners" do
    owners = [
      owner(:user),
      %{owner() | installation_id: 456, github_id: "ORG_2", login: "Second"}
    ]

    enqueue([response(installations(owners))])
    assert {:ok, ^owners} = GitHub.installations("ghu_synthetic")

    suspended =
      installation(%{owner() | installation_id: 789})
      |> Map.put("suspended_at", "2026-11-01T00:00:00Z")

    enqueue([response(%{"total_count" => 1, "installations" => [suspended]})])
    assert {:ok, []} = GitHub.installations("ghu_synthetic")
  end

  test "discovery pagination is complete, bounded, duplicate-safe and never follows provider links" do
    owners =
      Enum.map(
        1..101,
        &%{owner() | installation_id: &1, github_id: "OWNER_#{&1}", login: "Owner#{&1}"}
      )

    enqueue([
      response(
        %{
          "total_count" => 101,
          "installations" => Enum.take(owners, 100) |> Enum.map(&installation/1)
        },
        200,
        [{"link", "<https://evil.invalid/>; rel=next"}]
      ),
      response(%{"total_count" => 101, "installations" => [installation(List.last(owners))]})
    ])

    assert {:ok, ^owners} = GitHub.installations("ghu_synthetic")

    assert Enum.map(requests(), & &1.path) == [
             "/user/installations?per_page=100&page=1",
             "/user/installations?per_page=100&page=2"
           ]

    for body <- [
          %{"total_count" => 501, "installations" => []},
          %{"total_count" => 2, "installations" => [installation(owner())]},
          %{"total_count" => 2, "installations" => [installation(owner()), installation(owner())]}
        ] do
      enqueue([response(body)])
      assert {:error, :provider} = GitHub.installations("ghu_synthetic")
    end
  end

  test "installation-scoped organization PRs construct safe URLs and honest fields" do
    enqueue(snapshot_responses(graph()))

    assert {:ok, %{pull_requests: [row], total_count: 1, truncated: false}} =
             GitHub.installation_snapshot("ghu_synthetic", owner())

    assert row["url"] == "https://github.com/Acme/example1/pull/42"
    assert row["checks"] == "SUCCESS"
    assert row["review_decision"] == "APPROVED"
    assert length(requests()) == 6
    query_request = Enum.find(requests(), &(&1.path == "/graphql"))
    assert Jason.decode!(query_request.body)["variables"] == %{"id0" => "REPO_1"}
    assert Enum.all?(requests(), &(&1.timeout_ms > 0 and &1.timeout_ms <= 20_000))
  end

  test "personal installation owner is not interpreted as an organization" do
    selected = owner(:user)

    row =
      node(%{
        "repository" => %{
          "id" => "REPO_1",
          "name" => "example1",
          "owner" => graphql_owner(selected)
        }
      })

    body = %{"data" => %{"r0" => graph_repo(selected, repository(selected), [row])}}
    enqueue(snapshot_responses(body, selected))

    assert {:ok, %{pull_requests: [result], total_count: 1}} =
             GitHub.installation_snapshot("ghu_synthetic", selected)

    assert result["repository"] == "Acme/example1"
  end

  test "inaccessible, suspended or immutable-identity mismatched installations fail before querying PRs" do
    for accessible <- [
          [],
          [%{owner() | github_id: "OTHER"}],
          [%{owner() | login: "Other"}],
          [%{owner() | owner_type: :user}],
          [%{owner() | installation_id: 456}]
        ] do
      enqueue([response(installations(accessible))])
      assert {:error, :reconnect} = GitHub.installation_snapshot("ghu_synthetic", owner())
    end

    refute Enum.any?(requests(), &(&1.path == "/graphql"))
  end

  test "installation removal or repository selection change during reads cannot publish public PRs" do
    initial = Enum.take(snapshot_responses(graph()), 4)
    enqueue(initial ++ [response(installations([]))])
    assert {:error, :reconnect} = GitHub.installation_snapshot("ghu_synthetic", owner())
    enqueue(initial ++ [response(installations([owner()])), response(repositories([]))])
    assert {:error, :reconnect} = GitHub.installation_snapshot("ghu_synthetic", owner())
  end

  test "repository listings are bounded and immutable owner-bound before GraphQL" do
    for body <- [
          %{"total_count" => 101, "repositories" => []},
          %{"total_count" => 1, "repositories" => []},
          repositories([repository(%{owner() | github_id: "OTHER"})]),
          repositories([Map.put(repository(owner()), "name", "../escape")]),
          repositories([repository(owner()), repository(owner())])
        ] do
      enqueue([response(installations([owner()])), response(body)])
      assert {:error, :provider} = GitHub.installation_snapshot("ghu_synthetic", owner())
    end

    refute Enum.any?(requests(), &(&1.path == "/graphql"))
  end

  test "confirmed empty installation produces zero without an unscoped query" do
    enqueue([
      response(installations([owner()])),
      response(repositories([])),
      response(installations([owner()])),
      response(repositories([]))
    ])

    assert {:ok, %{pull_requests: [], total_count: 0, truncated: false}} =
             GitHub.installation_snapshot("ghu_synthetic", owner())

    refute Enum.any?(requests(), &(&1.path == "/graphql"))
  end

  test "per-repository counts aggregate across batches while only newest global first50 are retained" do
    selected = owner()
    repos = Enum.map(1..25, &repository(selected, &1))

    batch = fn request ->
      data =
        Jason.decode!(request.body)["variables"]
        |> Map.new(fn {key, id} ->
          index = id |> String.replace_prefix("REPO_", "") |> String.to_integer()
          repo = repository(selected, index)

          rows =
            Enum.map(1..3, fn number ->
              node(%{
                "number" => number,
                "repository" => %{
                  "id" => repo["node_id"],
                  "name" => repo["name"],
                  "owner" => graphql_owner(selected)
                },
                "updatedAt" => "2026-11-04T00:#{String.pad_leading(to_string(index), 2, "0")}:00Z"
              })
            end)

          {String.replace_prefix(key, "id", "r"), graph_repo(selected, repo, rows)}
        end)

      response(%{"data" => data})
    end

    enqueue(
      [
        response(installations([selected])),
        response(repositories(repos)),
        batch,
        batch
      ] ++
        List.duplicate(response(%{"total_count" => 0, "workflow_runs" => []}), 10) ++
        [response(installations([selected])), response(repositories(repos))]
    )

    assert {:ok,
            %{pull_requests: rows, total_count: 75, truncated: true, partial_reasons: reasons}} =
             GitHub.installation_snapshot("ghu_synthetic", selected)

    assert length(rows) == 50
    assert hd(rows)["repository"] == "Acme/example25"
    assert "first_50" in reasons
    assert Enum.count(requests(), &(&1.path == "/graphql")) == 2
  end

  test "missing core nodes and inaccessible optional fields remain explicitly partial" do
    for {body, reason} <- [
          {graph([node(), nil], 2), "core_incomplete"},
          {graph([node()], 3), "core_incomplete"},
          {graph([node(%{"commits" => nil, "reviewDecision" => nil})])
           |> Map.put("errors", [
             %{
               "path" => ["r0", "pullRequests", "nodes", 0, "commits"],
               "message" => "synthetic_secret"
             }
           ]), "optional_fields_unavailable"}
        ] do
      enqueue(snapshot_responses(body))

      assert {:ok, %{truncated: true, partial_reasons: reasons}} =
               GitHub.installation_snapshot("ghu_synthetic", owner())

      assert reason in reasons
    end
  end

  test "one large repository remains bounded to first50 without a search count cap" do
    rows = Enum.map(1..50, &node(%{"number" => &1}))
    enqueue(snapshot_responses(graph(rows, 1_200, true)))

    assert {:ok,
            %{
              pull_requests: results,
              total_count: 1_200,
              truncated: true,
              partial_reasons: reasons
            }} = GitHub.installation_snapshot("ghu_synthetic", owner())

    assert length(results) == 50
    assert "first_50" in reasons
  end

  test "unexpected repositories, identity mismatch and malformed PR nodes cannot escape the installation" do
    for body <- [
          %{"data" => %{"r0" => nil}},
          put_in(graph(), ["data", "r0", "id"], "UNSELECTED_PUBLIC_REPO"),
          put_in(graph(), ["data", "r0", "owner", "id"], "OTHER"),
          put_in(graph(), ["data", "r0", "name"], "other"),
          graph([
            node(%{
              "repository" => %{"name" => "public_unselected", "owner" => graphql_owner(owner())}
            })
          ]),
          graph([node(%{"number" => -1})]),
          graph([node(%{"updatedAt" => "bad"})]),
          graph([node(), node()]),
          graph([node()], 0),
          graph(List.duplicate(node(), 51), 51),
          Map.put(graph(), "errors", [
            %{"path" => ["r0", "pullRequests"], "message" => "synthetic_secret"}
          ])
        ] do
      enqueue(snapshot_responses(body))
      assert {:error, :provider} = GitHub.installation_snapshot("ghu_synthetic", owner())
    end
  end

  test "provider and transport errors stay safe categories and never successful empty snapshots" do
    for {status, headers, expected} <- [
          {401, [], :reconnect},
          {404, [], :reconnect},
          {403, [], :reconnect},
          {403, [{"x-ratelimit-remaining", "0"}], :rate_limited},
          {429, [], :rate_limited},
          {500, [], :provider},
          {302, [{"location", "https://evil.invalid/"}], :provider}
        ] do
      enqueue([response("synthetic_secret", status, headers)])
      assert {:error, ^expected} = GitHub.installation_snapshot("ghu_synthetic", owner())
    end

    enqueue([response(String.duplicate("x", 2 * 1024 * 1024 + 1))])
    assert {:error, :provider} = GitHub.user("ghu_synthetic")

    enqueue([
      response(installations([owner()])),
      response(repositories([repository(owner())])),
      response(Map.put(graph(), "errors", [%{"type" => "RATE_LIMITED"}]))
    ])

    assert {:error, :rate_limited} = GitHub.installation_snapshot("ghu_synthetic", owner())
    enqueue([{:error, %{private_detail: "synthetic_secret"}}])

    logs =
      capture_log(fn ->
        assert {:error, :provider} =
                 GitHub.refresh_token("Iv1.synthetic", "synthetic_client_secret", "ghr_synthetic")
      end)

    refute logs =~ "synthetic_secret"
    enqueue([fn _request -> raise "synthetic_secret" end])

    logs =
      capture_log(fn ->
        assert {:error, :provider} =
                 GitHub.refresh_token("Iv1.synthetic", "synthetic_client_secret", "ghr_synthetic")
      end)

    refute logs =~ "synthetic_secret"
  end

  test "verified repositories, issues and recent workflow statuses use constructed GitHub URLs" do
    body = put_in(graph(), ["data", "r0", "issues"], issue_connection([issue_node()]))
    replies = snapshot_responses(body)

    replies =
      List.replace_at(replies, 3, response(%{"total_count" => 1, "workflow_runs" => [run()]}))

    enqueue(replies)

    assert {:ok, snapshot} = GitHub.installation_snapshot("ghu_synthetic", owner())

    assert snapshot.repositories == [
             %{"id" => "REPO_1", "name" => "example1", "full_name" => "Acme/example1"}
           ]

    assert [pr] = snapshot.pull_requests
    assert pr["repository_id"] == "REPO_1"
    assert [issue] = snapshot.issues
    assert issue["repository_id"] == "REPO_1"
    assert issue["url"] == "https://github.com/Acme/example1/issues/43"
    assert issue["author"] == "octocat"
    assert issue["title"] == "Synthetic issue"
    assert snapshot.issue_count == 1
    refute snapshot.issues_truncated
    assert [workflow] = snapshot.workflow_runs
    assert workflow["url"] == "https://github.com/Acme/example1/actions/runs/99"
    assert workflow["repository_id"] == "REPO_1"
    assert workflow["status"] == "completed"
    assert workflow["conclusion"] == "success"
    refute snapshot.actions_truncated
    assert snapshot.partial_reasons == []

    assert Enum.any?(
             requests(),
             &(&1.path == "/repos/Acme/example1/actions/runs?per_page=10&page=1")
           )

    query =
      requests() |> Enum.find(&(&1.path == "/graphql")) |> Map.fetch!(:body) |> Jason.decode!()

    assert query["query"] =~ "issues(first: 50"
    refute query["query"] =~ "comments"
    refute query["query"] =~ "diff"
  end

  test "missing Issues and Actions permission preserves verified repository and PR data without false zero" do
    body =
      graph()
      |> put_in(["data", "r0", "issues"], nil)
      |> Map.put("errors", [
        %{"path" => ["r0", "issues"], "type" => "FORBIDDEN", "message" => "synthetic_secret"}
      ])

    replies = snapshot_responses(body) |> List.replace_at(3, response("synthetic_secret", 403))
    enqueue(replies)
    assert {:ok, snapshot} = GitHub.installation_snapshot("ghu_synthetic", owner())
    assert length(snapshot.pull_requests) == 1
    assert length(snapshot.repositories) == 1
    refute snapshot.truncated
    assert snapshot.issues == [] and snapshot.workflow_runs == []
    assert snapshot.issue_count == nil
    assert snapshot.issues_truncated and snapshot.actions_truncated
    assert "issues_unavailable" in snapshot.partial_reasons
    assert "actions_unavailable" in snapshot.partial_reasons
    refute inspect(snapshot) =~ "synthetic_secret"
  end

  test "nested issue field errors retain usable rows but mark the issue readout partial" do
    body =
      graph()
      |> put_in(["data", "r0", "issues"], issue_connection([issue_node(%{"author" => nil})]))
      |> Map.put("errors", [
        %{"path" => ["r0", "issues", "nodes", 0, "author"], "type" => "FORBIDDEN"}
      ])

    enqueue(snapshot_responses(body))
    assert {:ok, snapshot} = GitHub.installation_snapshot("ghu_synthetic", owner())
    assert [%{"author" => nil}] = snapshot.issues
    assert snapshot.issue_count == 1
    assert snapshot.issues_truncated
    assert "issues_unavailable" in snapshot.partial_reasons
    refute snapshot.truncated
  end

  test "issues are bounded independently and retain verified owner counts" do
    nodes = Enum.map(1..50, &issue_node(%{"number" => &1}))
    body = put_in(graph(), ["data", "r0", "issues"], issue_connection(nodes, 120, true))
    enqueue(snapshot_responses(body))
    assert {:ok, snapshot} = GitHub.installation_snapshot("ghu_synthetic", owner())
    assert length(snapshot.issues) == 50
    assert snapshot.issue_count == 120
    assert snapshot.issues_truncated
    refute snapshot.truncated
    assert "issues_first_50" in snapshot.partial_reasons
  end

  test "malformed, duplicate and cross-repository issue identities never become cached rows" do
    for issues <- [
          issue_connection([issue_node(%{"number" => -1})]),
          issue_connection([issue_node(%{"updatedAt" => "invalid"})]),
          issue_connection([issue_node(), issue_node()]),
          issue_connection([put_in(issue_node(), ["repository", "id"], "PUBLIC_UNSELECTED")]),
          issue_connection([put_in(issue_node(), ["repository", "owner", "id"], "OTHER_OWNER")])
        ] do
      enqueue(snapshot_responses(put_in(graph(), ["data", "r0", "issues"], issues)))
      assert {:error, :provider} = GitHub.installation_snapshot("ghu_synthetic", owner())
    end
  end

  test "malformed or foreign workflow runs remain unavailable instead of leaking data" do
    for invalid <- [
          run(%{"status" => "invented"}),
          run(%{"conclusion" => nil}),
          run(%{"updated_at" => "invalid"}),
          put_in(run(), ["repository", "node_id"], "PUBLIC_UNSELECTED"),
          put_in(run(), ["repository", "owner", "node_id"], "OTHER_OWNER")
        ] do
      replies = snapshot_responses(graph())

      enqueue(
        List.replace_at(replies, 3, response(%{"total_count" => 1, "workflow_runs" => [invalid]}))
      )

      assert {:ok, snapshot} = GitHub.installation_snapshot("ghu_synthetic", owner())
      assert snapshot.workflow_runs == []
      assert snapshot.actions_truncated
      assert "actions_unavailable" in snapshot.partial_reasons
      assert length(snapshot.repositories) == 1
    end
  end

  test "recent Actions pages never follow links and explicitly label older omitted runs" do
    runs = Enum.map(1..10, &run(%{"id" => &1, "status" => "in_progress", "conclusion" => nil}))

    replies =
      snapshot_responses(graph())
      |> List.replace_at(
        3,
        response(%{"total_count" => 11, "workflow_runs" => runs}, 200, [
          {"link", "<https://evil.invalid/logs>; rel=next"}
        ])
      )

    enqueue(replies)
    assert {:ok, snapshot} = GitHub.installation_snapshot("ghu_synthetic", owner())
    assert length(snapshot.workflow_runs) == 10

    assert Enum.all?(
             snapshot.workflow_runs,
             &(&1["status"] == "in_progress" and &1["conclusion"] == nil)
           )

    assert snapshot.actions_truncated
    assert "actions_recent_only" in snapshot.partial_reasons
    assert Enum.count(requests(), &String.contains?(&1.path, "/actions/")) == 1
  end

  test "Actions work is bounded across repositories with at most fifty cached runs" do
    selected = owner()
    repos = Enum.map(1..11, &repository(selected, &1))

    batch = fn request ->
      data =
        Jason.decode!(request.body)["variables"]
        |> Map.new(fn {key, id} ->
          repo = Enum.find(repos, &(&1["node_id"] == id))
          {String.replace_prefix(key, "id", "r"), graph_repo(selected, repo, [])}
        end)

      response(%{"data" => data})
    end

    actions = fn request ->
      repo = Enum.find(repos, &String.contains?(request.path, "/#{&1["name"]}/"))
      index = repo["id"]
      runs = Enum.map(1..10, &run(%{"id" => index * 100 + &1, "repository" => repo}))
      response(%{"total_count" => 10, "workflow_runs" => runs})
    end

    enqueue(
      [response(installations([selected])), response(repositories(repos)), batch] ++
        List.duplicate(actions, 10) ++
        [response(installations([selected])), response(repositories(repos))]
    )

    assert {:ok, snapshot} = GitHub.installation_snapshot("ghu_synthetic", selected)
    assert length(snapshot.repositories) == 11
    assert length(snapshot.workflow_runs) == 50
    assert snapshot.actions_truncated
    assert "actions_repository_limit" in snapshot.partial_reasons
    assert "actions_first_50" in snapshot.partial_reasons
    assert Enum.count(requests(), &String.contains?(&1.path, "/actions/")) == 10
  end

  test "rate-limited Actions are explicitly partial rather than a successful zero" do
    replies = snapshot_responses(graph()) |> List.replace_at(3, response("private", 429))
    enqueue(replies)
    assert {:ok, snapshot} = GitHub.installation_snapshot("ghu_synthetic", owner())
    assert snapshot.workflow_runs == []
    assert snapshot.actions_truncated
    assert "actions_rate_limited" in snapshot.partial_reasons
    assert length(snapshot.pull_requests) == 1
    assert length(snapshot.repositories) == 1
  end

  test "access revoked after populated optional reads discards the complete snapshot" do
    body = put_in(graph(), ["data", "r0", "issues"], issue_connection([issue_node()]))

    replies =
      snapshot_responses(body)
      |> List.replace_at(3, response(%{"total_count" => 1, "workflow_runs" => [run()]}))
      |> List.replace_at(4, response(installations([])))

    enqueue(replies)
    assert {:error, :reconnect} = GitHub.installation_snapshot("ghu_synthetic", owner())
  end

  defp issue_node(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 43,
        "title" => "Synthetic issue",
        "updatedAt" => "2026-11-04T00:00:00Z",
        "author" => %{"login" => "octocat"},
        "repository" => %{
          "id" => "REPO_1",
          "name" => "example1",
          "owner" => graphql_owner(owner())
        },
        "url" => "https://evil.invalid/private"
      },
      overrides
    )
  end

  defp issue_connection(nodes, count \\ nil, more \\ false),
    do: %{
      "totalCount" => count || length(nodes),
      "nodes" => nodes,
      "pageInfo" => %{"hasNextPage" => more}
    }

  defp run(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 99,
        "name" => "Synthetic CI",
        "status" => "completed",
        "conclusion" => "success",
        "updated_at" => "2026-11-04T00:00:00Z",
        "actor" => %{"login" => "octocat"},
        "repository" => repository(owner()),
        "html_url" => "https://evil.invalid/private"
      },
      overrides
    )
  end
end
