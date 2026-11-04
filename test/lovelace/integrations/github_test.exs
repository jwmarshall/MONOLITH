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
          "repository" => %{"name" => "example1", "owner" => graphql_owner(owner())},
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
      response(body),
      response(installations([selected])),
      response(repositories(repos))
    ]
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

  test "device authorization requests offline access without broad scopes or credentials in headers" do
    enqueue([
      response(%{
        "device_code" => "synthetic_device",
        "user_code" => "ABCD-EFGH",
        "expires_in" => 900,
        "interval" => 5,
        "verification_uri" => "https://evil.invalid/"
      })
    ])

    assert {:ok,
            %{
              device_code: "synthetic_device",
              user_code: "ABCD-EFGH",
              expires_in: 900,
              interval: 5
            }} = GitHub.device_code("Iv1.synthetic")

    [request] = requests()
    assert request.host == "github.com"
    assert request.path == "/login/device/code"

    assert URI.decode_query(request.body) == %{
             "client_id" => "Iv1.synthetic",
             "scope" => "offline_access"
           }

    refute List.keymember?(request.headers, "authorization", 0)
  end

  test "device polling handles pending, provider slowdown interval and sanitized terminal errors" do
    for {body, expected} <- [
          {%{"error" => "authorization_pending"}, {:error, :authorization_pending}},
          {%{"error" => "slow_down", "interval" => 17}, {:slow_down, 17}},
          {%{"error" => "slow_down", "interval" => 0}, {:error, :provider}},
          {%{"error" => "access_denied"}, {:error, :denied}},
          {%{"error" => "expired_token"}, {:error, :expired}},
          {%{"error" => "incorrect_device_code"}, {:error, :expired}},
          {%{"error" => "device_flow_disabled"}, {:error, :configuration}},
          {%{"error" => "incorrect_client_credentials"}, {:error, :configuration}},
          {%{"error" => "unknown private detail", "error_description" => "synthetic_secret"},
           {:error, :provider}}
        ] do
      enqueue([response(body)])
      assert GitHub.exchange_device("Iv1.synthetic", "synthetic_device") == expected
    end

    request = List.last(requests())

    assert URI.decode_query(request.body) == %{
             "client_id" => "Iv1.synthetic",
             "device_code" => "synthetic_device",
             "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
           }
  end

  test "exchanges and secretless refresh require expiring GitHub App token pairs" do
    enqueue([response(token_bundle()), response(token_bundle())])

    assert {:ok,
            %{access_token: "ghu_synthetic", refresh_token: "ghr_synthetic", expires_in: 28_800}} =
             GitHub.exchange_device("Iv1.synthetic", "synthetic_device")

    assert {:ok, %{refresh_token: "ghr_synthetic"}} =
             GitHub.refresh_token("Iv1.synthetic", "ghr_old")

    [_, refresh] = requests()
    assert refresh.host == "github.com"
    assert refresh.path == "/login/oauth/access_token"

    assert URI.decode_query(refresh.body) == %{
             "client_id" => "Iv1.synthetic",
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
      assert {:error, :provider} = GitHub.exchange_device("Iv1.synthetic", "synthetic_device")
    end

    enqueue([
      response(%{"error" => "bad_refresh_token", "error_description" => "synthetic_secret"})
    ])

    assert {:error, :reconnect} = GitHub.refresh_token("Iv1.synthetic", "ghr_old")
  end

  test "invalid request values and malformed device responses never become public codes" do
    assert {:error, :configuration} = GitHub.device_code("client\r\n")
    assert {:error, :provider} = GitHub.exchange_device("Iv1.synthetic", "device\r\n")
    assert {:error, :reconnect} = GitHub.refresh_token("Iv1.synthetic", "ghp_pat")
    assert requests() == []

    for code <- ["<script>", "ABCD-EFGH<script>", nil] do
      enqueue([
        response(%{
          "device_code" => "device",
          "user_code" => code,
          "expires_in" => 900,
          "interval" => 5
        })
      ])

      assert {:error, :provider} = GitHub.device_code("Iv1.synthetic")
    end
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
             GitHub.pull_requests("ghu_synthetic", owner())

    assert row["url"] == "https://github.com/Acme/example1/pull/42"
    assert row["checks"] == "SUCCESS"
    assert row["review_decision"] == "APPROVED"
    assert length(requests()) == 5
    query_request = Enum.find(requests(), &(&1.path == "/graphql"))
    assert Jason.decode!(query_request.body)["variables"] == %{"id0" => "REPO_1"}
    assert Enum.all?(requests(), &(&1.timeout_ms > 0 and &1.timeout_ms <= 20_000))
  end

  test "personal installation owner is not interpreted as an organization" do
    selected = owner(:user)
    row = node(%{"repository" => %{"name" => "example1", "owner" => graphql_owner(selected)}})
    body = %{"data" => %{"r0" => graph_repo(selected, repository(selected), [row])}}
    enqueue(snapshot_responses(body, selected))

    assert {:ok, %{pull_requests: [result], total_count: 1}} =
             GitHub.pull_requests("ghu_synthetic", selected)

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
      assert {:error, :reconnect} = GitHub.pull_requests("ghu_synthetic", owner())
    end

    refute Enum.any?(requests(), &(&1.path == "/graphql"))
  end

  test "installation removal or repository selection change during reads cannot publish public PRs" do
    initial = Enum.take(snapshot_responses(graph()), 3)
    enqueue(initial ++ [response(installations([]))])
    assert {:error, :reconnect} = GitHub.pull_requests("ghu_synthetic", owner())
    enqueue(initial ++ [response(installations([owner()])), response(repositories([]))])
    assert {:error, :reconnect} = GitHub.pull_requests("ghu_synthetic", owner())
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
      assert {:error, :provider} = GitHub.pull_requests("ghu_synthetic", owner())
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
             GitHub.pull_requests("ghu_synthetic", owner())

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
                "repository" => %{"name" => repo["name"], "owner" => graphql_owner(selected)},
                "updatedAt" => "2026-11-04T00:#{String.pad_leading(to_string(index), 2, "0")}:00Z"
              })
            end)

          {String.replace_prefix(key, "id", "r"), graph_repo(selected, repo, rows)}
        end)

      response(%{"data" => data})
    end

    enqueue([
      response(installations([selected])),
      response(repositories(repos)),
      batch,
      batch,
      response(installations([selected])),
      response(repositories(repos))
    ])

    assert {:ok,
            %{pull_requests: rows, total_count: 75, truncated: true, partial_reasons: reasons}} =
             GitHub.pull_requests("ghu_synthetic", selected)

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
               GitHub.pull_requests("ghu_synthetic", owner())

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
            }} = GitHub.pull_requests("ghu_synthetic", owner())

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
      assert {:error, :provider} = GitHub.pull_requests("ghu_synthetic", owner())
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
      assert {:error, ^expected} = GitHub.pull_requests("ghu_synthetic", owner())
    end

    enqueue([response(String.duplicate("x", 2 * 1024 * 1024 + 1))])
    assert {:error, :provider} = GitHub.user("ghu_synthetic")

    enqueue([
      response(installations([owner()])),
      response(repositories([repository(owner())])),
      response(Map.put(graph(), "errors", [%{"type" => "RATE_LIMITED"}]))
    ])

    assert {:error, :rate_limited} = GitHub.pull_requests("ghu_synthetic", owner())
    enqueue([{:error, %{private_detail: "synthetic_secret"}}])

    logs =
      capture_log(fn ->
        assert {:error, :provider} = GitHub.refresh_token("Iv1.synthetic", "ghr_synthetic")
      end)

    refute logs =~ "synthetic_secret"
    enqueue([fn _request -> raise "synthetic_secret" end])

    logs =
      capture_log(fn ->
        assert {:error, :provider} = GitHub.refresh_token("Iv1.synthetic", "ghr_synthetic")
      end)

    refute logs =~ "synthetic_secret"
  end
end
