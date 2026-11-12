defmodule Monolith.GitHubAuthTest do
  use MonolithWeb.ConnCase, async: false
  alias Monolith.GitHub.{Auth, ClientCredentials, Credentials, Operations}
  alias Monolith.OAuth.{Exchange, Worker}
  alias Monolith.Owner.Actions
  alias Monolith.Security.Vault
  alias Monolith.{TestGitHub, TestGitHubKeychain}
  alias Monolith.TestSupport.OAuthJobs
  @owner %{role: :local_owner}

  setup %{conn: conn} do
    start_supervised!({TestGitHub, []})
    settings = [github_provider: TestGitHub, github_keychain: TestGitHubKeychain]
    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:monolith, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:monolith, key, value) end)
    session = authenticate_owner(conn) |> get_session(:owner_session_token)

    assert {:ok, true} =
             Monolith.GitHub.save_client_credentials(
               "Iv1.synthetic",
               "synthetic_client_secret",
               "monolith-synthetic",
               actor: @owner
             )

    on_exit(fn ->
      Auth.cancel(session)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:monolith, key)
        {key, value} -> Application.put_env(:monolith, key, value)
      end)
    end)

    %{session: session, initial_tokens: TestGitHub.state().tokens}
  end

  test "state is session-bound and one-use; PKCE is supplied without exposing its verifier", %{
    session: session
  } do
    assert {:ok, url} = Auth.begin(session)
    params = URI.decode_query(URI.parse(url).query)
    assert params["redirect_uri"] == Auth.callback_url()
    assert params["code_challenge_method"] == "S256"
    assert params["scope"] == "offline_access"
    refute Map.has_key?(params, "client_secret")
    other = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Monolith.Owner.issue_session!(Actions.digest(other), DateTime.add(DateTime.utc_now(), 3600),
      actor: %{role: :owner_auth_service}
    )

    assert {:error, :expired} =
             OAuthJobs.complete(other, %{
               "state" => params["state"],
               "code" => "synthetic_code"
             })

    assert {:ok, _} =
             OAuthJobs.complete(session, %{
               "state" => params["state"],
               "code" => "synthetic_code"
             })

    assert {:error, :expired} =
             OAuthJobs.complete(session, %{
               "state" => params["state"],
               "code" => "synthetic_code"
             })

    [
      {:exchange_code, "Iv1.synthetic", "synthetic_client_secret", "synthetic_code", verifier, _}
      | _
    ] = TestGitHub.state().calls

    assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) ==
             params["code_challenge"]

    assert Auth.status(Actions.digest(session)) == %{status: :connected}

    assert %{connections: [_], organizations: owners, memberships: []} =
             Monolith.GitHub.directory!(actor: @owner)

    assert length(owners) == 2
  end

  test "concurrent callbacks exchange only once and cancellation fences delayed publication", %{
    session: session,
    initial_tokens: initial
  } do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    params = callback_params(session)
    task = Task.async(fn -> OAuthJobs.complete(session, params) end)
    assert_receive {:github_waiting, worker}
    assert {:error, :expired} = OAuthJobs.complete(session, params)
    assert :ok = Auth.cancel(session)
    assert {:ok, _} = Auth.begin(session)
    send(worker, :continue)
    assert {:error, _} = Task.await(task)
    assert TestGitHub.state().tokens == initial
    assert Enum.count(TestGitHub.state().calls, &match?({:exchange_code, _, _, _, _, _}, &1)) == 1
  end

  test "committed authorization rejects cancellation independently of its observer", %{
    session: session
  } do
    params = callback_params(session)
    assert {:ok, reference} = Auth.admit(session, params)
    job = Monolith.Repo.get!(Oban.Job, reference.job_id)
    assert job.args == %{"attempt_id" => reference.id}
    assert :ok = Worker.perform(job)
    assert {:ok, committed} = Auth.result(reference.id)
    assert {:error, :already_authorized} = Auth.cancel(session)
    assert Auth.status(Actions.digest(session)) == %{status: :connected}
    assert %{connections: [connection]} = Monolith.GitHub.directory!(actor: @owner)
    assert connection.id == committed.connection.id
    assert {:ok, _} = TestGitHubKeychain.get(connection.id)
    assert {:ok, %{status: :completed, outcome: :connected}} = Exchange.get(reference.id)
  end

  test "duplicate delivery cannot erase an original exchange that is still publishing", %{
    session: session
  } do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    assert {:ok, reference} = Auth.admit(session, callback_params(session))
    job = Monolith.Repo.get!(Oban.Job, reference.job_id)
    task = Task.async(fn -> Worker.perform(job) end)
    assert_receive {:github_waiting, worker}
    assert :ok = Worker.perform(job)
    assert {:ok, %{status: :claimed}} = Exchange.get(reference.id)
    send(worker, :continue)
    assert :ok = Task.await(task)
    assert {:ok, %{status: :completed, outcome: :connected}} = Exchange.get(reference.id)
    assert Enum.count(TestGitHub.state().calls, &match?({:exchange_code, _, _, _, _, _}, &1)) == 1
  end

  test "invalid composed callback configuration refuses authorization", %{session: session} do
    previous = Application.get_env(:monolith, :github_callback_url)
    on_exit(fn -> Application.put_env(:monolith, :github_callback_url, previous) end)

    Application.put_env(
      :monolith,
      :github_callback_url,
      "https://example.invalid/auth/github/callback"
    )

    assert Auth.callback_url() == nil
    assert {:error, :configuration} = Auth.begin(session)
    assert TestGitHub.state().calls == []
  end

  test "revoked sessions refuse exchange commit", %{session: session, initial_tokens: initial} do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    params = callback_params(session)
    task = Task.async(fn -> OAuthJobs.complete(session, params) end)
    assert_receive {:github_waiting, worker}
    Monolith.Owner.logout(session)
    send(worker, :continue)
    assert {:error, _} = Task.await(task)
    assert TestGitHub.state().tokens == initial
  end

  test "global Lock fences a token exchange already in flight", %{
    session: session,
    initial_tokens: initial
  } do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    params = callback_params(session)
    task = Task.async(fn -> OAuthJobs.complete(session, params) end)
    assert_receive {:github_waiting, worker}
    Vault.lock()
    send(worker, :continue)
    assert {:error, _} = Task.await(task)
    assert TestGitHub.state().tokens == initial
    assert {:error, _} = Monolith.Owner.verify_session(session)
  end

  test "changing client credentials fences in-flight authorization", %{session: session} do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    params = callback_params(session)
    task = Task.async(fn -> OAuthJobs.complete(session, params) end)
    assert_receive {:github_waiting, worker}

    assert {:ok, true} =
             Monolith.GitHub.save_client_credentials(
               "Iv1.replacement",
               "new_client_secret",
               "replacement-app",
               actor: @owner
             )

    saved = TestGitHub.state().tokens
    send(worker, :continue)
    assert {:error, _} = Task.await(task)
    assert TestGitHub.state().tokens == saved
    assert %{connections: []} = Monolith.GitHub.directory!(actor: @owner)
  end

  for operation <- [:disconnect_account, :disconnect] do
    test "#{operation} fences an already-running authorization", %{session: session} do
      assert {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())

      TestGitHub.configure(
        exchange_response: {:wait, self(), {:ok, TestGitHub.bundle("replacement")}}
      )

      params = callback_params(session)
      task = Task.async(fn -> OAuthJobs.complete(session, params) end)
      assert_receive {:github_waiting, worker}

      id =
        if unquote(operation) == :disconnect_account,
          do: initial.connection.id,
          else: hd(initial.organizations).id

      assert {:ok, _} = apply(Monolith.GitHub, unquote(operation), [id, [actor: @owner]])
      saved = TestGitHub.state().tokens
      send(worker, :continue)
      assert {:error, _} = Task.await(task)
      assert TestGitHub.state().tokens == saved
    end
  end

  test "unknown token exchange outcomes consume the attempt even after auth server restart", %{
    session: session,
    initial_tokens: initial
  } do
    TestGitHub.configure(exchange_response: {:error, :provider})
    params = callback_params(session)
    assert {:error, _} = OAuthJobs.complete(session, params)
    assert {:error, :expired} = OAuthJobs.complete(session, params)

    supervisor =
      if Process.whereis(Monolith.Security.ProtectedSupervisor),
        do: Monolith.Security.ProtectedSupervisor,
        else: Monolith.Supervisor

    :ok = Supervisor.terminate_child(supervisor, Auth)
    {:ok, _} = Supervisor.restart_child(supervisor, Auth)
    assert {:error, :expired} = OAuthJobs.complete(session, params)
    assert TestGitHub.state().tokens == initial
  end

  test "expired authorization state never contacts the provider", %{session: session} do
    params = callback_params(session)

    :sys.replace_state(Auth, fn attempts ->
      Map.new(attempts, fn {key, attempt} ->
        {key, %{attempt | expires: System.monotonic_time(:millisecond) - 1}}
      end)
    end)

    assert {:error, :expired} = OAuthJobs.complete(session, params)
    assert TestGitHub.state().calls == []
  end

  test "refresh uses the stored client secret and binds the rotated bundle", %{session: session} do
    {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())
    expire(initial.connection.id)

    assert {:ok, "github_access_rotated"} =
             Credentials.access_token(initial.connection.id)

    assert {:refresh_token, "Iv1.synthetic", "synthetic_client_secret", _} =
             Enum.find(TestGitHub.state().calls, &match?({:refresh_token, _, _, _}, &1))

    {:ok, encoded} = TestGitHubKeychain.get(initial.connection.id)
    {:ok, client} = ClientCredentials.current()
    assert Jason.decode!(encoded)["client_generation"] == client.generation
  end

  test "changing clients cannot reuse or refresh the previous app token pair", %{session: session} do
    {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())

    assert {:ok, true} =
             Monolith.GitHub.save_client_credentials(
               "Iv1.other",
               "other_secret",
               "other-app",
               actor: @owner
             )

    assert {:error, :reconnect} = Credentials.access_token(initial.connection.id)
    refute Enum.any?(TestGitHub.state().calls, &match?({:refresh_token, _, _, _}, &1))
    assert %{connections: [account]} = Monolith.GitHub.directory!(actor: @owner)
    assert account.status == :reauthorization
  end

  test "changing credentials during refresh refuses a delayed rotated pair", %{session: session} do
    {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())
    expire(initial.connection.id)
    TestGitHub.configure(refresh_response: {:wait, self(), {:ok, TestGitHub.bundle("late_pair")}})
    task = Task.async(fn -> Credentials.access_token(initial.connection.id) end)
    assert_receive {:github_waiting, worker}

    assert {:ok, true} =
             Monolith.GitHub.save_client_credentials(
               "Iv1.other",
               "other_secret",
               "other-app",
               actor: @owner
             )

    stored = TestGitHub.state().tokens
    send(worker, :continue)
    assert {:error, :reconnect} = Task.await(task)
    assert TestGitHub.state().tokens == stored
  end

  test "uncertain refresh is durably reserved and never retried", %{session: session} do
    {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())
    expire(initial.connection.id)
    TestGitHub.configure(refresh_response: {:error, :provider})
    assert {:error, _} = Credentials.access_token(initial.connection.id)
    assert {:error, :reconnect} = Credentials.access_token(initial.connection.id)
    assert Enum.count(TestGitHub.state().calls, &match?({:refresh_token, _, _, _}, &1)) == 1
  end

  defp expire(id) do
    {:ok, encoded} = TestGitHubKeychain.get(id)
    value = encoded |> Jason.decode!() |> Map.put("expires_at", 0) |> Jason.encode!()
    :ok = TestGitHubKeychain.put(id, value)
  end

  defp callback_params(session) do
    {:ok, url} = Auth.begin(session)
    %{"state" => URI.decode_query(URI.parse(url).query)["state"], "code" => "synthetic_code"}
  end
end
