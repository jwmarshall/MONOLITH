defmodule Lovelace.Integrations.GitHub.TransportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Lovelace.GitHub.Auth
  alias Lovelace.Integrations.GitHub.Transport

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        method: "GET",
        host: "api.github.com",
        path: "/user",
        headers: [{"authorization", "Bearer synthetic_secret"}],
        body: "",
        timeout_ms: 100
      },
      overrides
    )
  end

  defp graphql(overrides \\ %{}) do
    request(
      Map.merge(
        %{
          method: "POST",
          path: "/graphql",
          headers: [
            {"authorization", "Bearer synthetic_secret"},
            {"content-type", "application/json"}
          ],
          body:
            Jason.encode!(%{
              query: "query($id: ID!) { node(id: $id) { id } }",
              variables: %{id: "REPO_1"}
            })
        },
        overrides
      )
    )
  end

  defp oauth(
         path \\ "/login/oauth/access_token",
         params \\ %{
           client_id: "Iv1.synthetic",
           client_secret: "synthetic_secret",
           code: "synthetic_code",
           code_verifier: String.duplicate("v", 43),
           redirect_uri: Auth.callback_url()
         }
       ) do
    request(%{
      method: "POST",
      host: "github.com",
      path: path,
      headers: [
        {"accept", "application/json"},
        {"content-type", "application/x-www-form-urlencoded"}
      ],
      body: URI.encode_query(params)
    })
  end

  test "exact API allowlist accepts only identity, bounded discovery and read-only GraphQL" do
    assert :ok = Transport.validate(request())
    assert :ok = Transport.validate(graphql())

    for path <- [
          "/user/installations?per_page=100&page=1",
          "/user/installations?per_page=100&page=5",
          "/user/installations/123/repositories?per_page=100&page=1"
        ] do
      assert :ok = Transport.validate(request(%{path: path}))
    end

    for overrides <- [
          %{host: "api.github.com.evil.invalid"},
          %{host: "github.com"},
          %{path: "/user?token=secret"},
          %{path: "/orgs/acme"},
          %{path: "/repos/acme/repo/pulls"},
          %{path: "/user/installations?per_page=100&page=6"},
          %{path: "/user/installations?per_page=100&page=1&token=secret"},
          %{path: "/user/installations/../repositories?per_page=100&page=1"},
          %{path: "/user/installations/0/repositories?per_page=100&page=1"},
          %{path: "/user/installations/123/repositories?per_page=100&page=1#fragment"},
          %{method: "DELETE"},
          %{method: "POST", path: "/user"},
          %{method: "GET", path: "/graphql"},
          %{path: "/graphql?query=mutation"},
          %{path: "https://evil.invalid/"},
          %{body: "credentials"},
          %{timeout_ms: 30_001},
          %{timeout_ms: 0},
          %{body: String.duplicate("x", 65_537)},
          %{headers: [{"authorization", "Bearer fake\r\nInjected: bad"}]},
          %{headers: [{"authorization", String.duplicate("x", 16_385)}]},
          %{headers: [{"host", "evil.invalid"}, {"authorization", "Bearer fake"}]},
          %{headers: [{"authorization", "Bearer one"}, {"authorization", "Bearer two"}]},
          %{headers: [{"authorization", "Basic fake"}]},
          %{headers: []}
        ] do
      assert {:error, :invalid_request} = Transport.validate(request(overrides))
    end
  end

  test "GraphQL rejects mutations, alternate operation selection and non-JSON payloads" do
    for body <- [
          Jason.encode!(%{
            query: "mutation { deleteIssue(input: {}) { clientMutationId } }",
            variables: %{}
          }),
          Jason.encode!(%{
            query: "query($id: ID!) { node(id: $id) { id } } mutation X { unsafe }",
            variables: %{}
          }),
          Jason.encode!(%{
            query: "query($id: ID!) { node(id: $id) { id } }",
            variables: %{},
            operationName: "X"
          }),
          Jason.encode!(%{query: "subscription { anything }", variables: %{}}),
          "not-json"
        ] do
      assert {:error, :invalid_request} = Transport.validate(graphql(%{body: body}))
    end
  end

  test "web exchange and refresh require secret-bearing exact forms without API authorization" do
    exchange = oauth()

    refresh =
      oauth("/login/oauth/access_token", %{
        client_id: "Iv1.synthetic",
        client_secret: "synthetic_secret",
        refresh_token: "ghr_synthetic",
        grant_type: "refresh_token"
      })

    assert :ok = Transport.validate(exchange)
    assert :ok = Transport.validate(refresh)

    assert {:error, :invalid_request} =
             Transport.validate(%{
               refresh
               | headers: [{"authorization", "Bearer synthetic_secret"} | refresh.headers]
             })

    for invalid <- [
          %{oauth() | path: "/login/oauth/authorize"},
          %{oauth() | path: "/login/device/code"},
          %{oauth() | host: "github.com.evil.invalid"},
          %{oauth() | body: "client_id=Iv1.synthetic&scope=repo"},
          %{oauth() | body: "client_id=Iv1.synthetic&scope=offline_access&client_secret=secret"},
          %{oauth() | body: "client_id=Iv1.synthetic&scope=repo&scope=offline_access"},
          %{refresh | body: refresh.body <> "&client_secret=secret"},
          %{exchange | body: exchange.body <> "&refresh_token=ghr_other"},
          %{
            exchange
            | body:
                URI.encode_query(%{
                  client_id: "Iv1.synthetic",
                  client_secret: "synthetic_secret",
                  code: "synthetic_code",
                  code_verifier: String.duplicate("v", 43),
                  redirect_uri: "https://evil.invalid/callback"
                })
          },
          %{oauth() | headers: [{"content-type", "application/json"}]},
          %{oauth() | method: "GET"}
        ] do
      assert {:error, :invalid_request} = Transport.validate(invalid)
    end
  end

  test "production connector is disabled in tests without HTTP instrumentation or payload logs" do
    parent = self()
    handler = {__MODULE__, make_ref()}

    events = [
      [:req, :request, :start],
      [:req, :request, :stop],
      [:finch, :request, :start],
      [:finch, :request, :stop]
    ]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _measurements, metadata, pid ->
          send(pid, {:http_instrumentation, event, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    logs =
      capture_log(fn ->
        for valid <- [
              request(),
              graphql(),
              oauth(),
              oauth("/login/oauth/access_token", %{
                client_id: "Iv1.synthetic",
                client_secret: "synthetic_secret",
                refresh_token: "ghr_synthetic",
                grant_type: "refresh_token"
              })
            ] do
          assert {:error, :transport_error} = Transport.request(valid)
        end

        assert {:error, :invalid_request} = Transport.request(request(%{host: "evil.invalid"}))
      end)

    refute logs =~ "synthetic_secret"
    refute logs =~ "ghr_synthetic"
    refute_receive {:http_instrumentation, _, _}
  end
end
