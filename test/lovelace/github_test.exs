defmodule Lovelace.GitHubTest do
  use Lovelace.DataCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite
  alias Lovelace.GitHub
  alias Lovelace.GitHub.{Connection, Operations, Organization, PollWorker, WorkspaceOrganization}
  alias Lovelace.Owner.Actions
  alias Lovelace.TestGitHub
  @owner %{role: :local_owner}
  @service %{role: :github_service}

  setup do
    start_supervised!({TestGitHub, []})
    keys = [:github_provider, :github_keychain, :github]
    previous = Map.new(keys, &{&1, Application.get_env(:lovelace, &1)})
    Application.put_env(:lovelace, :github_provider, TestGitHub)
    Application.put_env(:lovelace, :github_keychain, Lovelace.TestGitHubKeychain)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:lovelace, key, value),
          else: Application.delete_env(:lovelace, key)
      end
    end)

    Lovelace.Owner.configure!("synthetic GitHub owner password", actor: %{role: :owner_setup})

    GitHub.save_client_credentials!(
      "Iv1.synthetic",
      "synthetic_client_secret",
      "lovelace-synthetic",
      actor: @owner
    )

    session = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Lovelace.Owner.issue_session!(
      Actions.digest(session),
      DateTime.add(DateTime.utc_now(), 3600),
      actor: %{role: :owner_auth_service}
    )

    a = Lovelace.Workspaces.create_workspace!("GitHub A", actor: @owner)
    b = Lovelace.Workspaces.create_workspace!("GitHub B", actor: @owner)
    %{a: a, b: b, session: session}
  end

  defp directory, do: GitHub.directory!(actor: @owner)
  defp current(id), do: Enum.find(directory().organizations, &(&1.id == id))
  defp account(id), do: Enum.find(directory().connections, &(&1.id == id))

  defp tokens do
    Map.reject(TestGitHub.state().tokens, fn {_id, value} ->
      match?({:ok, %{"client_secret" => _}}, Jason.decode(value))
    end)
  end

  defp authorize(c, token \\ "github_access_fake") do
    assert {:ok, result} = Operations.authorize(c.session, TestGitHub.bundle(token))
    result
  end

  defp connect(c, login \\ "acme") do
    result = authorize(c)
    org = Enum.find(directory().organizations, &(&1.login == login))
    GitHub.attach!(c.a.id, org.id, actor: @owner)
    GitHub.poll!(org.id, org.generation, actor: @owner)
    {current(org.id), account(result.connection.id)}
  end

  defp update_org(org, attrs),
    do: org |> Ash.Changeset.for_update(:publish, attrs, actor: @service) |> Ash.update!()

  defp update_account(account, attrs),
    do: account |> Ash.Changeset.for_update(:transition, attrs, actor: @service) |> Ash.update!()

  defp due(org), do: update_org(org, %{next_poll_at: DateTime.add(DateTime.utc_now(), -1)})

  defp expire_token(id) do
    {:ok, value} = Lovelace.TestGitHubKeychain.get(id)
    value = Jason.decode!(value) |> Map.put("expires_at", System.system_time(:second) - 1)
    :ok = Lovelace.TestGitHubKeychain.put(id, Jason.encode!(value))
  end

  defp empty_snapshot,
    do:
      {:ok,
       %{
         pull_requests: [],
         repositories: [],
         issues: [],
         workflow_runs: [],
         issue_count: 0,
         issues_truncated: false,
         actions_truncated: false,
         total_count: 0,
         truncated: false,
         partial_reasons: []
       }}

  test "one account discovers personal and organization installations, reusable across workspaces",
       c do
    result = authorize(c)
    assert length(directory().connections) == 1

    assert Enum.sort(Enum.map(directory().organizations, & &1.owner_type)) == [
             :organization,
             :user
           ]

    assert directory().memberships == []

    for org <- directory().organizations do
      assert org.connection_id == result.connection.id
      assert {:ok, true} = GitHub.attach(c.a.id, org.id, actor: @owner)
      assert {:ok, true} = GitHub.attach(c.b.id, org.id, actor: @owner)
      assert {:ok, true} = GitHub.attach(c.b.id, org.id, actor: @owner)
    end

    assert length(directory().memberships) == 4
    assert Map.keys(tokens()) == [result.connection.id]
    {:ok, stored} = Lovelace.TestGitHubKeychain.get(result.connection.id)
    assert Jason.decode!(stored)["access_token"] == "github_access_fake"
    refute inspect(directory()) =~ "github_access_fake"
    refute inspect(result) =~ "refresh_token"
  end

  test "owner detach and disconnect do not delete the account shared by other owners", c do
    {org, connection} = connect(c)
    personal = Enum.find(directory().organizations, &(&1.owner_type == :user))
    GitHub.attach!(c.b.id, org.id, actor: @owner)
    GitHub.attach!(c.a.id, personal.id, actor: @owner)
    assert {:ok, true} = GitHub.detach(c.a.id, org.id, actor: @owner)
    assert length(directory().memberships) == 2
    assert {:ok, %{status: :disconnected}} = GitHub.disconnect(org.id, actor: @owner)
    assert current(org.id).pull_requests == []
    assert current(org.id).total_count == nil
    assert current(org.id).generation != org.generation
    assert [%{organization_id: personal_id}] = directory().memberships
    assert personal_id == personal.id
    assert {:ok, _} = Lovelace.TestGitHubKeychain.get(connection.id)
    assert {:ok, "github_access_fake"} = Operations.access_token(connection.id)
    assert {:error, _} = GitHub.attach(c.a.id, org.id, actor: @owner)
  end

  test "all public operations require local owner and raw mutations reject owner", c do
    {org, connection} = connect(c)

    for actor <- [nil, %{role: "local_owner"}, %{role: :github_service}] do
      assert {:error, _} = GitHub.directory(actor: actor)
      assert {:error, _} = GitHub.discover(connection.id, actor: actor)
      assert {:error, _} = GitHub.disconnect_account(connection.id, actor: actor)
      assert {:error, _} = GitHub.attach(c.b.id, org.id, actor: actor)

      assert {:error, _} =
               GitHub.attach_repositories(c.b.id, org.id, ["REPO_SYNTHETIC"], actor: actor)

      assert {:error, _} = GitHub.detach(c.a.id, org.id, actor: actor)
      assert {:error, _} = GitHub.disconnect(org.id, actor: actor)
      assert {:error, _} = GitHub.refresh(org.id, actor: actor)
      assert {:error, _} = GitHub.poll(org.id, org.generation, actor: actor)
    end

    assert {:error, _} =
             org
             |> Ash.Changeset.for_update(:publish, %{generation: Ash.UUID.generate()},
               actor: @owner
             )
             |> Ash.update()

    assert {:error, _} =
             connection
             |> Ash.Changeset.for_update(:transition, %{status: :ready}, actor: @owner)
             |> Ash.update()

    assert {:error, _} =
             WorkspaceOrganization
             |> Ash.Changeset.for_create(
               :attach,
               %{workspace_id: c.b.id, organization_id: org.id},
               actor: @owner
             )
             |> Ash.create()

    assert {:error, _} = Organization |> Ash.Query.for_read(:read) |> Ash.read()
    assert {:error, _} = Connection |> Ash.Query.for_read(:read) |> Ash.read()
  end

  test "authorization checks owner session and expiring bundle before provider work", c do
    assert {:error, :denied} = Operations.authorize("invalid", TestGitHub.bundle())
    assert {:error, :provider} = Operations.authorize(c.session, %{access_token: "old_pat"})

    assert {:error, :provider} =
             Operations.authorize(c.session, %{TestGitHub.bundle() | refresh_token: ""})

    assert TestGitHub.state().calls == []
    assert tokens() == %{}
  end

  test "renames and same-user reauthorization preserve immutable owner and memberships", c do
    {org, connection} = connect(c)

    TestGitHub.configure(
      installation_sets: %{"replacement" => [TestGitHub.owner(%{login: "renamed"})]}
    )

    result = authorize(c, "replacement")
    renamed = current(org.id)
    assert renamed.login == "renamed"
    assert renamed.github_id == org.github_id
    assert renamed.generation != org.generation
    assert result.connection.id == connection.id
    GitHub.attach!(c.b.id, org.id, actor: @owner)
    assert length(directory().memberships) == 2
    assert Map.keys(tokens()) == [connection.id]
    assert {:ok, "replacement"} = Operations.access_token(connection.id)
  end

  test "another GitHub user cannot silently take an existing installation owner", c do
    {org, connection} = connect(c)

    TestGitHub.configure(
      identities: %{"other_access" => %{github_id: "USER_OTHER", login: "other"}}
    )

    assert {:error, :denied} = Operations.authorize(c.session, TestGitHub.bundle("other_access"))
    assert current(org.id).connection_id == connection.id
    assert length(directory().connections) == 1
    assert length(directory().memberships) == 1
    assert {:ok, "github_access_fake"} = Operations.access_token(connection.id)
  end

  test "separate GitHub users retain separate UUID credentials and owner caches", c do
    {first, first_account} = connect(c)
    other_owner = TestGitHub.owner(%{github_id: "ORG_OTHER", login: "other", installation_id: 3})

    TestGitHub.configure(
      identities: %{"other_access" => %{github_id: "USER_OTHER", login: "other"}},
      installation_sets: %{"other_access" => [other_owner]}
    )

    second = authorize(c, "other_access")
    other = Enum.find(directory().organizations, &(&1.github_id == "ORG_OTHER"))
    GitHub.attach!(c.b.id, other.id, actor: @owner)
    GitHub.poll!(other.id, other.generation, actor: @owner)
    assert first_account.id != second.connection.id
    assert map_size(tokens()) == 2
    GitHub.disconnect_account!(first_account.id, actor: @owner)
    assert current(first.id).status == :disconnected
    assert current(other.id).total_count == 1
    assert {:ok, "other_access"} = Operations.access_token(second.connection.id)
  end

  test "discovery preserves memberships and fences removed installations without false zero", c do
    {org, connection} = connect(c)

    TestGitHub.configure(
      installation_sets: %{
        "github_access_fake" => [
          TestGitHub.owner(%{
            github_id: "USER_SYNTHETIC",
            login: "synthetic",
            owner_type: :user,
            installation_id: 2
          })
        ]
      }
    )

    assert {:ok, _} = GitHub.discover(connection.id, actor: @owner)
    removed = current(org.id)
    assert removed.status == :reauthorization
    assert removed.last_error == :reconnect
    assert removed.total_count == nil and removed.pull_requests == []
    assert removed.generation != org.generation
    assert length(directory().memberships) == 1
    calls = TestGitHub.state().calls
    assert {:ok, %{skipped: true}} = GitHub.poll(org.id, org.generation, actor: @owner)
    assert TestGitHub.state().calls == calls
  end

  test "discovery provider failure is not an empty successful installation list", c do
    {org, connection} = connect(c)
    TestGitHub.configure(installation_response: {:error, :provider})
    assert {:error, _} = GitHub.discover(connection.id, actor: @owner)
    assert current(org.id).generation == org.generation
    assert current(org.id).total_count == 1
    assert length(directory().memberships) == 1
  end

  test "refresh only queues identifiers and rate-limited reads retain honest freshness", c do
    {org, _} = connect(c)
    calls = TestGitHub.state().calls
    GitHub.refresh!(org.id, actor: @owner)
    assert TestGitHub.state().calls == calls

    assert_enqueued(
      worker: PollWorker,
      args: %{organization_id: org.id, generation: org.generation}
    )

    TestGitHub.configure(response: {:error, :rate_limited})

    assert {:ok, %{last_error: :rate_limited}} =
             GitHub.poll(org.id, org.generation, actor: @owner)

    prior = current(org.id)
    assert prior.pull_requests == org.pull_requests and prior.fetched_at == org.fetched_at
    assert prior.total_count == 1
    calls = TestGitHub.state().calls
    GitHub.refresh!(org.id, actor: @owner)
    GitHub.poll!(org.id, org.generation, actor: @owner)
    assert TestGitHub.state().calls == calls
    assert DateTime.diff(prior.next_poll_at, DateTime.utc_now()) > 800
  end

  test "provider failure never invents zero and 24-hour expiration preserves membership", c do
    {org, _} = connect(c)
    observed = DateTime.add(DateTime.utc_now(), -86_401)
    update_org(org, %{fetched_at: observed})
    expired = current(org.id)
    assert expired.pull_requests == [] and expired.total_count == nil
    assert expired.fetched_at == observed
    assert length(directory().memberships) == 1
    TestGitHub.configure(response: {:error, :provider})
    due(expired)
    GitHub.poll!(org.id, org.generation, actor: @owner)
    assert current(org.id).total_count == nil
    assert current(org.id).last_error == :provider
  end

  test "revoked installation fails closed rather than publishing a zero count", c do
    {org, _} = connect(c)
    due(org)
    TestGitHub.configure(response: {:error, :reconnect})
    GitHub.poll!(org.id, org.generation, actor: @owner)
    assert current(org.id).status == :reauthorization
    assert current(org.id).total_count == nil
    assert current(org.id).pull_requests == []
    assert length(directory().memberships) == 1
  end

  test "delayed poll cannot republish after owner or account disconnect", c do
    {org, connection} = connect(c)
    due(org)
    TestGitHub.configure(response: {:wait, self(), empty_snapshot()})
    task = Task.async(fn -> GitHub.poll(org.id, org.generation, actor: @owner) end)
    assert_receive {:github_waiting, worker}
    GitHub.disconnect_account!(connection.id, actor: @owner)
    send(worker, :continue)
    assert {:ok, %{skipped: true}} = Task.await(task)
    assert current(org.id).status == :disconnected
    assert current(org.id).total_count == nil
    assert directory().memberships == []
    assert {:error, :not_found} = Lovelace.TestGitHubKeychain.get(connection.id)
  end

  test "pending authorization cannot undo a later owner disconnect", c do
    {org, _} = connect(c)
    owners = [TestGitHub.owner()]
    TestGitHub.configure(installation_response: {:wait, self(), {:ok, owners}})
    task = Task.async(fn -> Operations.authorize(c.session, TestGitHub.bundle("replacement")) end)
    assert_receive {:github_waiting, worker}
    GitHub.disconnect!(org.id, actor: @owner)
    send(worker, :continue)
    assert {:error, :unavailable} = Task.await(task)
    assert current(org.id).status == :disconnected
    assert directory().memberships == []
  end

  test "pending authorization cannot undo account disconnect or owner logout", c do
    {org, connection} = connect(c)
    TestGitHub.configure(installation_response: {:wait, self(), {:ok, [TestGitHub.owner()]}})
    task = Task.async(fn -> Operations.authorize(c.session, TestGitHub.bundle("replacement")) end)
    assert_receive {:github_waiting, worker}
    GitHub.disconnect_account!(connection.id, actor: @owner)
    Lovelace.Owner.logout!(c.session)
    send(worker, :continue)
    assert {:error, :denied} = Task.await(task)
    assert current(org.id).status == :disconnected
    assert tokens() == %{}
  end

  test "Auth commit cancellation prevents all final credential and resource writes", c do
    assert {:error, :denied} =
             Operations.authorize(c.session, TestGitHub.bundle(), fn _fun -> {:error, :denied} end)

    assert directory().connections == []
    assert directory().organizations == []
    assert tokens() == %{}
  end

  test "delayed discovery cannot reattach an owner disconnected during HTTP", c do
    {org, connection} = connect(c)
    TestGitHub.configure(installation_response: {:wait, self(), {:ok, [TestGitHub.owner()]}})
    task = Task.async(fn -> GitHub.discover(connection.id, actor: @owner) end)
    assert_receive {:github_waiting, worker}
    GitHub.disconnect!(org.id, actor: @owner)
    send(worker, :continue)
    assert {:error, _} = Task.await(task)
    assert current(org.id).status == :disconnected
    assert directory().memberships == []
  end

  test "temporary keychain read failure preserves connections and snapshots until retry", c do
    {org, connection} = connect(c)
    stored = tokens()
    memberships = directory().memberships
    calls = TestGitHub.state().calls
    due(org)
    TestGitHub.configure(keychain_error: :unavailable)

    assert {:ok, _} = GitHub.poll(org.id, org.generation, actor: @owner)
    assert account(connection.id).status == :ready
    assert account(connection.id).generation == connection.generation
    failed = current(org.id)
    assert failed.status == :ready
    assert failed.generation == org.generation
    assert failed.last_error == :keychain
    assert failed.pull_requests == org.pull_requests
    assert failed.repositories == org.repositories
    assert failed.issues == org.issues
    assert failed.workflow_runs == org.workflow_runs
    assert failed.total_count == org.total_count
    assert failed.fetched_at == org.fetched_at
    assert failed.claim_id == nil
    assert TestGitHub.state().calls == calls
    assert tokens() == stored
    assert directory().memberships == memberships

    TestGitHub.configure(keychain_error: nil)
    due(failed)
    assert {:ok, _} = GitHub.poll(org.id, org.generation, actor: @owner)
    assert current(org.id).last_error == nil
    assert current(org.id).total_count == org.total_count
    assert account(connection.id).status == :ready
    assert tokens() == stored
    refute Enum.any?(TestGitHub.state().calls, &(elem(&1, 0) == :refresh_token))
    assert directory().memberships == memberships
  end

  test "shared refresh serializes rotation and stores new credentials only once", c do
    {_, connection} = connect(c)
    expire_token(connection.id)
    TestGitHub.configure(refresh_response: {:wait, self(), {:ok, TestGitHub.bundle("rotated")}})
    first = Task.async(fn -> Operations.access_token(connection.id) end)
    assert_receive {:github_waiting, worker}
    assert account(connection.id).status == :refreshing
    assert account(connection.id).generation != connection.generation
    second = Task.async(fn -> Operations.access_token(connection.id) end)
    send(worker, :continue)
    assert {:ok, "rotated"} = Task.await(first)
    assert {:ok, "rotated"} = Task.await(second)
    assert Enum.count(TestGitHub.state().calls, &(elem(&1, 0) == :refresh_token)) == 1
    {:ok, stored} = Lovelace.TestGitHubKeychain.get(connection.id)
    assert Jason.decode!(stored)["refresh_token"] == "refresh_rotated"
    assert account(connection.id).status == :ready
  end

  test "unknown refresh outcome durably requires sign-in and never replays old refresh", c do
    {org, connection} = connect(c)
    expire_token(connection.id)
    TestGitHub.configure(refresh_response: {:error, :provider})
    assert {:error, :provider} = Operations.access_token(connection.id)
    assert account(connection.id).status == :reauthorization
    assert current(org.id).total_count == nil
    assert length(directory().memberships) == 1
    assert {:error, :reconnect} = Operations.access_token(connection.id)
    assert Enum.count(TestGitHub.state().calls, &(elem(&1, 0) == :refresh_token)) == 1
    assert {:ok, _} = Lovelace.TestGitHubKeychain.get(connection.id)
  end

  test "interrupted committed rotation is fenced without contacting the provider again", c do
    {_, connection} = connect(c)
    update_account(connection, %{status: :refreshing, generation: Ash.UUID.generate()})
    calls = TestGitHub.state().calls
    assert {:error, :reconnect} = Operations.access_token(connection.id)
    assert TestGitHub.state().calls == calls
    assert account(connection.id).status == :reauthorization
  end

  test "rotated credential save failure cannot replay the previously stored refresh", c do
    {_, connection} = connect(c)
    expire_token(connection.id)
    TestGitHub.configure(keychain_put_error: :unavailable)
    assert {:error, :keychain} = Operations.access_token(connection.id)
    TestGitHub.configure(keychain_put_error: nil)
    assert {:error, :reconnect} = Operations.access_token(connection.id)
    assert account(connection.id).status == :reauthorization
    assert Enum.count(TestGitHub.state().calls, &(elem(&1, 0) == :refresh_token)) == 1
  end

  test "delayed rotating response cannot restore a disconnected account", c do
    {org, connection} = connect(c)
    expire_token(connection.id)
    TestGitHub.configure(refresh_response: {:wait, self(), {:ok, TestGitHub.bundle("late")}})
    task = Task.async(fn -> Operations.access_token(connection.id) end)
    assert_receive {:github_waiting, worker}
    GitHub.disconnect_account!(connection.id, actor: @owner)
    send(worker, :continue)
    assert {:error, :reconnect} = Task.await(task)
    assert account(connection.id).status == :disconnected
    assert current(org.id).status == :disconnected
    assert {:error, :not_found} = Lovelace.TestGitHubKeychain.get(connection.id)
  end

  test "failed credential deletion stays visible and explicit retry completes cleanup", c do
    {org, connection} = connect(c)
    TestGitHub.configure(keychain_delete_error: :locked)
    assert {:error, _} = GitHub.disconnect_account(connection.id, actor: @owner)
    assert account(connection.id).status == :disconnected
    assert account(connection.id).last_error == :keychain
    assert current(org.id).total_count == nil and directory().memberships == []
    TestGitHub.configure(keychain_delete_error: nil)

    assert {:ok, %{status: :disconnected}} =
             GitHub.disconnect_account(connection.id, actor: @owner)

    assert {:error, :not_found} = Lovelace.TestGitHubKeychain.get(connection.id)
  end

  test "legacy owners retain membership and credential until explicit owner cleanup", c do
    org =
      Organization
      |> Ash.Changeset.for_create(
        :connect,
        %{
          id: Ash.UUID.generate(),
          github_id: "LEGACY_ORG",
          login: "legacy",
          generation: Ash.UUID.generate(),
          status: :reauthorization,
          legacy_credential: true,
          last_error: :reconnect,
          next_poll_at: DateTime.utc_now()
        },
        actor: @service
      )
      |> Ash.create!()

    WorkspaceOrganization
    |> Ash.Changeset.for_create(
      :attach,
      %{workspace_id: c.a.id, organization_id: org.id},
      actor: @service
    )
    |> Ash.create!()

    Lovelace.TestGitHubKeychain.put(org.id, "synthetic_legacy_pat")
    assert {:ok, %{skipped: true}} = GitHub.poll(org.id, org.generation, actor: @owner)
    assert TestGitHub.state().calls == []
    assert length(directory().memberships) == 1
    assert {:ok, "synthetic_legacy_pat"} = Lovelace.TestGitHubKeychain.get(org.id)
    assert {:error, _} = GitHub.attach(c.b.id, org.id, actor: @owner)
    GitHub.disconnect!(org.id, actor: @owner)
    assert {:error, :not_found} = Lovelace.TestGitHubKeychain.get(org.id)
    assert directory().memberships == []
  end

  test "legacy immutable owner can be authorized without losing membership or deleting original",
       c do
    org =
      Organization
      |> Ash.Changeset.for_create(
        :connect,
        %{
          id: Ash.UUID.generate(),
          github_id: "ORG_ACME",
          login: "acme",
          generation: Ash.UUID.generate(),
          status: :reauthorization,
          legacy_credential: true,
          last_error: :reconnect,
          next_poll_at: DateTime.utc_now()
        },
        actor: @service
      )
      |> Ash.create!()

    WorkspaceOrganization
    |> Ash.Changeset.for_create(
      :attach,
      %{workspace_id: c.a.id, organization_id: org.id},
      actor: @service
    )
    |> Ash.create!()

    Lovelace.TestGitHubKeychain.put(org.id, "synthetic_legacy_pat")
    result = authorize(c)
    assert current(org.id).connection_id == result.connection.id
    assert current(org.id).status == :ready
    assert length(directory().memberships) == 1
    assert {:ok, "synthetic_legacy_pat"} = Lovelace.TestGitHubKeychain.get(org.id)
    GitHub.disconnect_account!(result.connection.id, actor: @owner)
    assert current(org.id).legacy_credential
    assert {:ok, "synthetic_legacy_pat"} = Lovelace.TestGitHubKeychain.get(org.id)
    assert directory().memberships == []
    GitHub.disconnect!(org.id, actor: @owner)
    assert {:error, :not_found} = Lovelace.TestGitHubKeychain.get(org.id)
    refute current(org.id).legacy_credential
    assert {:error, :not_found} = Lovelace.TestGitHubKeychain.get(result.connection.id)
  end

  test "claims fence overlapping polls and expired claims permit a new winner", c do
    {org, _} = connect(c)
    due(org)
    TestGitHub.configure(response: {:wait, self(), empty_snapshot()})
    task = Task.async(fn -> GitHub.poll(org.id, org.generation, actor: @owner) end)
    assert_receive {:github_waiting, worker}
    assert {:ok, %{skipped: true}} = GitHub.poll(org.id, org.generation, actor: @owner)
    update_org(current(org.id), %{claimed_until: DateTime.add(DateTime.utc_now(), -1)})
    TestGitHub.configure(response: :ok)
    assert {:ok, _} = GitHub.poll(org.id, org.generation, actor: @owner)
    send(worker, :continue)
    assert {:ok, %{skipped: true}} = Task.await(task)
    assert current(org.id).total_count == 1
  end

  test "pending authorization cannot undo account disconnect with a still-valid owner session",
       c do
    {org, connection} = connect(c)
    TestGitHub.configure(installation_response: {:wait, self(), {:ok, [TestGitHub.owner()]}})
    task = Task.async(fn -> Operations.authorize(c.session, TestGitHub.bundle("replacement")) end)
    assert_receive {:github_waiting, worker}
    GitHub.disconnect_account!(connection.id, actor: @owner)
    send(worker, :continue)
    assert {:error, :unavailable} = Task.await(task)
    assert account(connection.id).status == :disconnected
    assert current(org.id).status == :disconnected
    assert tokens() == %{}
  end

  test "successful reauthorization fences a previously running poll", c do
    {org, _} = connect(c)
    due(org)
    TestGitHub.configure(response: {:wait, self(), empty_snapshot()})
    task = Task.async(fn -> GitHub.poll(org.id, org.generation, actor: @owner) end)
    assert_receive {:github_waiting, worker}
    replacement = authorize(c, "replacement")
    send(worker, :continue)
    assert {:ok, %{skipped: true}} = Task.await(task)
    assert current(org.id).generation != org.generation
    assert current(org.id).fetched_at == nil
    assert current(org.id).total_count == nil
    assert {:ok, "replacement"} = Operations.access_token(replacement.connection.id)
  end

  test "late discovery failure cannot fence a newly authorized account", c do
    {org, connection} = connect(c)
    TestGitHub.configure(installation_response: {:wait, self(), {:error, :reconnect}})
    task = Task.async(fn -> GitHub.discover(connection.id, actor: @owner) end)
    assert_receive {:github_waiting, worker}
    TestGitHub.configure(installation_response: :ok)
    replacement = authorize(c, "replacement")
    send(worker, :continue)
    assert {:error, _} = Task.await(task)
    assert account(connection.id).generation == replacement.connection.generation
    assert account(connection.id).status == :ready
    assert current(org.id).status == :ready
    assert {:ok, "replacement"} = Operations.access_token(connection.id)
  end

  test "keychain authorization failure remains visible without enabling an old credential", c do
    {org, connection} = connect(c)
    TestGitHub.configure(keychain_put_error: :locked)
    assert {:error, :keychain} = Operations.authorize(c.session, TestGitHub.bundle("replacement"))
    TestGitHub.configure(keychain_put_error: nil)
    assert account(connection.id).status == :reauthorization
    assert account(connection.id).last_error == :keychain
    assert current(org.id).total_count == nil
    assert length(directory().memberships) == 1
    assert {:error, :reconnect} = Operations.access_token(connection.id)
  end

  test "invalid duplicate or oversized discovery cannot persist installation identities", c do
    for owners <- [
          [TestGitHub.owner(), TestGitHub.owner()],
          List.duplicate(TestGitHub.owner(), 501)
        ] do
      TestGitHub.configure(installation_response: {:ok, owners})
      assert {:error, :provider} = Operations.authorize(c.session, TestGitHub.bundle())
      assert directory().connections == []
      assert directory().organizations == []
      assert tokens() == %{}
    end
  end

  test "minute sweep discovers due owners and stale jobs never perform provider work", c do
    {org, _} = connect(c)
    due(org)
    assert :ok = Operations.sweep()

    assert_enqueued(
      worker: PollWorker,
      args: %{organization_id: org.id, generation: org.generation}
    )

    authorize(c, "replacement")
    calls = TestGitHub.state().calls

    assert :ok =
             PollWorker.perform(%Oban.Job{
               args: %{"organization_id" => org.id, "generation" => org.generation}
             })

    assert TestGitHub.state().calls == calls
    assert current(org.id).generation != org.generation
  end

  test "repository selections are independent per workspace, editable and immutable-ID scoped",
       c do
    first = TestGitHub.repository()

    second =
      TestGitHub.repository(%{
        "id" => "REPO_SECOND",
        "name" => "second",
        "full_name" => "acme/second"
      })

    TestGitHub.configure(
      repositories: [first, second],
      rows: [
        TestGitHub.row(),
        TestGitHub.row(%{
          "number" => 10,
          "repository_id" => "REPO_SECOND",
          "repository" => "acme/second"
        })
      ],
      issues: [
        TestGitHub.issue(),
        TestGitHub.issue(%{
          "number" => 11,
          "repository_id" => "REPO_SECOND",
          "repository" => "acme/second"
        })
      ],
      workflow_runs: [
        TestGitHub.workflow_run(),
        TestGitHub.workflow_run(%{
          "id" => 12,
          "repository_id" => "REPO_SECOND",
          "repository" => "acme/second"
        })
      ]
    )

    {org, _} = connect(c)
    assert org.repositories == [first, second]
    assert org.issue_count == 2
    assert length(org.pull_requests) == 2
    assert length(org.issues) == 2
    assert length(org.workflow_runs) == 2
    refute org.issues_truncated
    refute org.actions_truncated

    assert {:ok, true} = GitHub.attach_repositories(c.a.id, org.id, [first["id"]], actor: @owner)
    assert {:ok, true} = GitHub.attach_repositories(c.b.id, org.id, [second["id"]], actor: @owner)
    memberships = directory().memberships
    a = Enum.find(memberships, &(&1.workspace_id == c.a.id))
    b = Enum.find(memberships, &(&1.workspace_id == c.b.id))
    assert a.repository_ids == [first["id"]]
    assert b.repository_ids == [second["id"]]

    assert {:ok, true} =
             GitHub.attach_repositories(c.a.id, org.id, [second["id"], second["id"]],
               actor: @owner
             )

    edited = Enum.find(directory().memberships, &(&1.workspace_id == c.a.id))
    assert edited.id == a.id
    assert edited.repository_ids == [second["id"]]
    assert length(directory().memberships) == 2

    assert {:ok, true} = GitHub.attach(c.a.id, org.id, actor: @owner)
    assert Enum.find(directory().memberships, &(&1.workspace_id == c.a.id)).repository_ids == []

    assert Enum.find(directory().memberships, &(&1.workspace_id == c.b.id)).repository_ids == [
             second["id"]
           ]
  end

  test "repository attach rejects empty, unknown, cross-owner and expired selections", c do
    {org, _} = connect(c)
    personal = Enum.find(directory().organizations, &(&1.owner_type == :user))
    foreign = TestGitHub.repository(%{"id" => "PERSONAL_REPO", "full_name" => "synthetic/repo"})
    TestGitHub.configure(repositories: [foreign], rows: [], issues: [], workflow_runs: [])
    GitHub.poll!(personal.id, personal.generation, actor: @owner)
    assert current(personal.id).repositories == [foreign]

    for selection <- [[], ["UNKNOWN"], ["PERSONAL_REPO"], ["REPO_SYNTHETIC", "UNKNOWN"]] do
      assert {:error, _} = GitHub.attach_repositories(c.b.id, org.id, selection, actor: @owner)
    end

    assert length(directory().memberships) == 1
    update_org(org, %{fetched_at: DateTime.add(DateTime.utc_now(), -86_401)})

    assert {:error, _} =
             GitHub.attach_repositories(c.b.id, org.id, ["REPO_SYNTHETIC"], actor: @owner)

    assert current(org.id).repositories == []
    assert {:ok, true} = GitHub.attach(c.b.id, org.id, actor: @owner)
  end

  test "missing optional snapshot fields clear old optional rows without fabricating zero", c do
    {org, _} = connect(c)
    assert org.issues != [] and org.workflow_runs != []
    due(org)

    TestGitHub.configure(
      response: {:ok, %{pull_requests: [], total_count: 0, truncated: false, partial_reasons: []}}
    )

    GitHub.poll!(org.id, org.generation, actor: @owner)
    current = current(org.id)
    assert current.repositories == []
    assert current.issues == [] and current.workflow_runs == []
    assert current.issue_count == nil
    assert current.issues_truncated and current.actions_truncated
    assert "issues_unavailable" in current.partial_reasons
    assert "actions_unavailable" in current.partial_reasons
    assert current.total_count == 0
  end

  test "all read caches expire together and reauthorization clears every readout", c do
    {org, _} = connect(c)
    update_org(org, %{fetched_at: DateTime.add(DateTime.utc_now(), -86_401)})
    expired = current(org.id)
    assert_empty_readouts(expired)

    due(expired)
    GitHub.poll!(org.id, org.generation, actor: @owner)
    assert current(org.id).issues != []
    authorize(c, "replacement")
    assert_empty_readouts(current(org.id))
    assert length(directory().memberships) == 1
  end

  test "late populated readouts cannot reappear after owner disconnect", c do
    {org, _} = connect(c)
    due(org)

    late =
      {:ok,
       %{
         repositories: org.repositories,
         pull_requests: org.pull_requests,
         issues: org.issues,
         workflow_runs: org.workflow_runs,
         issue_count: org.issue_count,
         total_count: org.total_count,
         issues_truncated: false,
         actions_truncated: false,
         truncated: false,
         partial_reasons: []
       }}

    TestGitHub.configure(response: {:wait, self(), late})
    task = Task.async(fn -> GitHub.poll(org.id, org.generation, actor: @owner) end)
    assert_receive {:github_waiting, worker}
    GitHub.disconnect!(org.id, actor: @owner)
    send(worker, :continue)
    assert {:ok, %{skipped: true}} = Task.await(task)
    assert_empty_readouts(current(org.id))
    assert directory().memberships == []
  end

  defp assert_empty_readouts(org) do
    assert org.repositories == []
    assert org.pull_requests == []
    assert org.issues == []
    assert org.workflow_runs == []
    assert org.issue_count == nil
    assert org.total_count == nil
    refute org.issues_truncated
    refute org.actions_truncated
  end
end
