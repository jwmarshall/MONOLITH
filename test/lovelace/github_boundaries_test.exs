defmodule Lovelace.GitHubBoundariesTest.FailingKeychain do
  @behaviour Lovelace.Integrations.GitHub.Keychain

  def get(_id), do: raise("synthetic credential service failure")
  def put(id, value), do: Lovelace.TestGitHubKeychain.put(id, value)
  def delete(id), do: Lovelace.TestGitHubKeychain.delete(id)
end

defmodule Lovelace.GitHubBoundariesTest do
  use Lovelace.DataCase, async: false

  alias Lovelace.GitHub
  alias Lovelace.GitHub.{Auth, Operations}
  alias Lovelace.Owner.Actions
  alias Lovelace.{TestGitHub, TestGitHubKeychain}

  @owner %{role: :local_owner}

  setup do
    start_supervised!({TestGitHub, []})
    settings = [github_provider: TestGitHub, github_keychain: TestGitHubKeychain]
    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:lovelace, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:lovelace, key, value) end)

    Lovelace.Owner.configure!("synthetic GitHub boundary password", actor: %{role: :owner_setup})

    GitHub.save_client_credentials!("Iv1.synthetic", "synthetic_secret", "synthetic-app",
      actor: @owner
    )

    session = issue_session()
    workspace = Lovelace.Workspaces.create_workspace!("GitHub boundaries", actor: @owner)

    on_exit(fn ->
      Auth.cancel(session)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lovelace, key)
        {key, value} -> Application.put_env(:lovelace, key, value)
      end)
    end)

    %{session: session, workspace: workspace}
  end

  test "discovery rejects a different authenticated user and clears all owner readouts",
       context do
    {org, account} = connect(context)
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "github:" <> org.id)
    TestGitHub.configure(user_response: {:ok, %{github_id: "DIFFERENT_USER", login: "other"}})
    calls = TestGitHub.state().calls

    assert {:error, _} = GitHub.discover(account.id, actor: @owner)
    assert TestGitHub.state().calls == calls ++ [{:user, "github_access_fake"}]
    assert_receive {:github_changed, id}
    assert id == org.id
    assert current_account(account.id).status == :reauthorization
    assert current_account(account.id).last_error == :reconnect
    assert current_org(org.id).pull_requests == []
    assert current_org(org.id).repositories == []
    assert current_org(org.id).issues == []
    assert current_org(org.id).workflow_runs == []
    assert current_org(org.id).total_count == nil
    assert [%{organization_id: organization_id}] = directory().memberships
    assert organization_id == org.id
    assert {:error, :reconnect} = Operations.access_token(account.id)
  end

  for generation <- [nil, "generation-from-a-restored-vault"] do
    test "a restored credential with client generation #{inspect(generation)} cannot be reused",
         context do
      {org, account} = connect(context)
      {:ok, json} = TestGitHubKeychain.get(account.id)
      restored = Jason.decode!(json) |> Map.put("client_generation", unquote(generation))
      :ok = TestGitHubKeychain.put(account.id, Jason.encode!(restored))
      calls = TestGitHub.state().calls

      assert {:error, :reconnect} = Operations.access_token(account.id)
      assert TestGitHub.state().calls == calls
      assert current_account(account.id).generation != account.generation
      assert current_account(account.id).status == :reauthorization
      assert current_org(org.id).status == :reauthorization
      assert current_org(org.id).total_count == nil
      assert length(directory().memberships) == 1
    end
  end

  test "credential service exceptions publish an unavailable first read rather than zero",
       context do
    {:ok, authorized} = Operations.authorize(context.session, TestGitHub.bundle())
    org = Enum.find(directory().organizations, &(&1.owner_type == :organization))
    GitHub.attach!(context.workspace.id, org.id, actor: @owner)
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "github:" <> org.id)
    calls = TestGitHub.state().calls

    Application.put_env(
      :lovelace,
      :github_keychain,
      Lovelace.GitHubBoundariesTest.FailingKeychain
    )

    assert {:ok, %{last_error: :unavailable}} =
             GitHub.poll(org.id, org.generation, actor: @owner)

    assert_receive {:github_changed, id}
    assert id == org.id
    failed = current_org(org.id)
    assert failed.total_count == nil
    assert failed.issue_count == nil
    assert failed.fetched_at == nil
    assert failed.claim_id == nil
    assert failed.claimed_until == nil
    assert failed.pull_requests == []
    assert failed.status == :ready
    assert DateTime.compare(failed.next_poll_at, DateTime.utc_now()) == :gt
    assert current_account(authorized.connection.id).status == :ready
    assert TestGitHub.state().calls == calls
  end

  test "unexpected discovery errors are sanitized without replacing a known good snapshot",
       context do
    {org, account} = connect(context)
    TestGitHub.configure(user_response: {:error, %{private_token: "synthetic_private_value"}})

    assert {:error, error} = GitHub.discover(account.id, actor: @owner)
    refute inspect(error) =~ "synthetic_private_value"
    assert current_account(account.id).status == :ready
    assert current_account(account.id).last_error == nil
    assert current_org(org.id).pull_requests == org.pull_requests
    assert current_org(org.id).fetched_at == org.fetched_at
    assert current_org(org.id).total_count == org.total_count
  end

  test "failed owner credential removal remains disconnected and can be explicitly retried",
       context do
    {org, account} = connect(context)
    :ok = TestGitHubKeychain.put(org.id, "synthetic_retained_legacy_credential")
    TestGitHub.configure(keychain_delete_error: :locked)

    assert {:error, _} = GitHub.disconnect(org.id, actor: @owner)
    assert current_org(org.id).status == :disconnected
    assert current_org(org.id).last_error == :keychain
    assert current_org(org.id).repositories == []
    assert directory().memberships == []
    assert current_account(account.id).status == :ready
    assert {:ok, "synthetic_retained_legacy_credential"} = TestGitHubKeychain.get(org.id)

    TestGitHub.configure(keychain_delete_error: nil)

    assert {:ok, %{status: :disconnected, last_error: nil}} =
             GitHub.disconnect(org.id, actor: @owner)

    assert {:error, :not_found} = TestGitHubKeychain.get(org.id)
    assert {:ok, "github_access_fake"} = Operations.access_token(account.id)
    assert {:error, _} = GitHub.refresh(org.id, actor: @owner)
  end

  test "cancelling pending OAuth invalidates its callback without cancelling the replacement",
       context do
    old = callback_params(context.session)
    initial_tokens = TestGitHub.state().tokens
    assert :ok = Auth.cancel(context.session)
    assert Auth.status(Actions.digest(context.session)) == %{status: :idle}
    replacement = callback_params(context.session)

    assert {:error, :expired} = Auth.complete(context.session, old)
    assert Auth.status(Actions.digest(context.session)) == %{status: :pending}
    assert TestGitHub.state().calls == []
    assert TestGitHub.state().tokens == initial_tokens
    assert {:ok, _} = Auth.complete(context.session, replacement)
    assert Auth.status(Actions.digest(context.session)) == %{status: :connected}
    assert Enum.count(TestGitHub.state().calls, &match?({:exchange_code, _, _, _, _, _}, &1)) == 1
  end

  test "an exchange worker crash fails its caller and consumes the code", context do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    params = callback_params(context.session)
    initial_tokens = TestGitHub.state().tokens
    task = Task.async(fn -> Auth.complete(context.session, params) end)
    assert_receive {:github_waiting, worker}
    Process.exit(worker, :kill)

    assert {:error, :unavailable} = Task.await(task)
    assert Auth.status(Actions.digest(context.session)) == %{status: :failed}
    assert {:error, :expired} = Auth.complete(context.session, params)
    assert TestGitHub.state().tokens == initial_tokens
    assert directory().connections == []
  end

  test "OAuth capacity rejects a seventeenth pending flow but reclaims a cancelled slot" do
    supervisor =
      if Process.whereis(Lovelace.Security.ProtectedSupervisor),
        do: Lovelace.Security.ProtectedSupervisor,
        else: Lovelace.Supervisor

    :ok = Supervisor.terminate_child(supervisor, Auth)
    {:ok, _} = Supervisor.restart_child(supervisor, Auth)
    sessions = Enum.map(1..17, fn _ -> issue_session() end)
    on_exit(fn -> Enum.each(sessions, &Auth.cancel/1) end)
    {active, [overflow]} = Enum.split(sessions, 16)
    params = Enum.map(active, &callback_params/1)

    assert {:error, :busy} = Auth.begin(overflow)
    assert TestGitHub.state().calls == []
    assert :ok = Auth.cancel(hd(active))
    assert {:ok, _} = Auth.begin(overflow)
    assert Auth.status(Actions.digest(overflow)) == %{status: :pending}
    assert {:error, :expired} = Auth.complete(hd(active), hd(params))
    assert Auth.status(Actions.digest(Enum.at(active, 1))) == %{status: :pending}
    assert directory().connections == []
  end

  defp issue_session do
    session = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Lovelace.Owner.issue_session!(Actions.digest(session), DateTime.add(DateTime.utc_now(), 3600),
      actor: %{role: :owner_auth_service}
    )

    session
  end

  defp callback_params(session) do
    assert {:ok, url} = Auth.begin(session)
    state = URI.decode_query(URI.parse(url).query)["state"]
    %{"state" => state, "code" => "synthetic_code"}
  end

  defp connect(context) do
    assert {:ok, authorized} = Operations.authorize(context.session, TestGitHub.bundle())
    org = Enum.find(directory().organizations, &(&1.owner_type == :organization))
    GitHub.attach!(context.workspace.id, org.id, actor: @owner)
    GitHub.poll!(org.id, org.generation, actor: @owner)
    {current_org(org.id), current_account(authorized.connection.id)}
  end

  defp directory, do: GitHub.directory!(actor: @owner)
  defp current_org(id), do: Enum.find(directory().organizations, &(&1.id == id))
  defp current_account(id), do: Enum.find(directory().connections, &(&1.id == id))
end

defmodule Lovelace.GitHubBoundaryAdapterTest.Transport do
  alias Lovelace.Integrations.GitHub.Transport, as: GitHubTransport

  def request(request, []) do
    :ok = GitHubTransport.validate(request)

    Agent.get_and_update(__MODULE__, fn %{responses: [response | rest]} = state ->
      {response, %{state | responses: rest, requests: state.requests ++ [request]}}
    end)
  end
end

defmodule Lovelace.GitHubBoundaryAdapterTest do
  use ExUnit.Case, async: false

  alias Lovelace.GitHubBoundaryAdapterTest.Transport
  alias Lovelace.Integrations.GitHub

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

  test "malformed installation entries cannot turn a valid prefix into partial discovery" do
    for entry <- [nil, %{"id" => 2, "account" => %{"type" => "Bot"}}] do
      enqueue([response(%{"total_count" => 2, "installations" => [installation(), entry]})])
      assert {:error, :provider} = GitHub.installations("ghu_synthetic")
      assert length(requests()) == 1
    end
  end

  test "non-object successful HTTP payloads remain provider errors" do
    for payload <- ["not JSON", "[]", "null"] do
      enqueue([{:ok, %{status: 200, headers: [], body: payload}}])
      assert {:error, :provider} = GitHub.installations("ghu_synthetic")
      assert length(requests()) == 1
    end
  end

  test "malformed GraphQL error envelopes never become empty successful snapshots" do
    for graph <- [Map.put(graph(), "errors", %{}), %{"errors" => []}] do
      enqueue([response(installations()), response(repositories()), response(graph)])
      assert {:error, :provider} = GitHub.pull_requests("ghu_synthetic", owner())

      assert Enum.map(requests(), & &1.path) == [
               "/user/installations?per_page=100&page=1",
               "/user/installations/1/repositories?per_page=100&page=1",
               "/graphql"
             ]
    end
  end

  test "malformed GraphQL owner identity prevents publishing even empty repository readouts" do
    graph = put_in(graph(), ["data", "r0", "owner"], nil)
    enqueue([response(installations()), response(repositories()), response(graph)])
    assert {:error, :provider} = GitHub.pull_requests("ghu_synthetic", owner())
    assert length(requests()) == 3
  end

  test "an inconsistent Actions page marks Actions unavailable without discarding verified counts" do
    enqueue(snapshot_responses(%{"total_count" => 1, "workflow_runs" => []}))
    assert {:ok, snapshot} = GitHub.pull_requests("ghu_synthetic", owner())
    assert snapshot.total_count == 0
    assert snapshot.issue_count == 0

    assert snapshot.repositories == [
             %{"id" => "REPO_1", "name" => "repo", "full_name" => "acme/repo"}
           ]

    assert snapshot.workflow_runs == []
    assert snapshot.actions_truncated
    assert "actions_unavailable" in snapshot.partial_reasons
    refute snapshot.truncated
  end

  test "rate limiting during final scope verification discards otherwise successful readouts" do
    responses = snapshot_responses(%{"total_count" => 0, "workflow_runs" => []})
    enqueue(List.replace_at(responses, 4, {:ok, %{status: 429, headers: [], body: "private"}}))
    assert {:error, :rate_limited} = GitHub.pull_requests("ghu_synthetic", owner())
    assert length(requests()) == 5
  end

  defp owner,
    do: %{installation_id: 1, github_id: "ORG_ACME", login: "acme", owner_type: :organization}

  defp installation do
    %{
      "id" => 1,
      "account" => %{"node_id" => "ORG_ACME", "login" => "acme", "type" => "Organization"}
    }
  end

  defp installations, do: %{"total_count" => 1, "installations" => [installation()]}

  defp repositories do
    %{
      "total_count" => 1,
      "repositories" => [
        %{
          "id" => 1,
          "node_id" => "REPO_1",
          "name" => "repo",
          "owner" => installation()["account"]
        }
      ]
    }
  end

  defp graph do
    connection = %{"totalCount" => 0, "nodes" => [], "pageInfo" => %{"hasNextPage" => false}}

    %{
      "errors" => [],
      "data" => %{
        "r0" => %{
          "id" => "REPO_1",
          "name" => "repo",
          "owner" => %{"id" => "ORG_ACME", "login" => "acme", "__typename" => "Organization"},
          "pullRequests" => connection,
          "issues" => connection
        }
      }
    }
  end

  defp snapshot_responses(actions) do
    Enum.map(
      [installations(), repositories(), graph(), actions, installations(), repositories()],
      &response/1
    )
  end

  defp response(body), do: {:ok, %{status: 200, headers: [], body: Jason.encode!(body)}}

  defp enqueue(responses),
    do: Agent.update(Transport, fn _ -> %{responses: responses, requests: []} end)

  defp requests, do: Agent.get(Transport, & &1.requests)
end
