defmodule Lovelace.GitHubAuthTest do
  use LovelaceWeb.ConnCase, async: false
  alias Lovelace.GitHub.{Auth, ClientCredentials, Operations}
  alias Lovelace.Owner.Actions
  alias Lovelace.Security.{Secret, Vault}
  alias Lovelace.{TestGitHub, TestGitHubKeychain}
  alias LovelaceWeb.Endpoint
  @owner %{role: :local_owner}

  setup %{conn: conn} do
    start_supervised!({TestGitHub, []})
    settings = [github_provider: TestGitHub, github_keychain: TestGitHubKeychain]
    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:lovelace, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:lovelace, key, value) end)
    session = authenticate_owner(conn) |> get_session(:owner_session_token)

    assert {:ok, true} =
             Lovelace.GitHub.save_client_credentials(
               "Iv1.synthetic",
               "synthetic_client_secret",
               "lovelace-synthetic",
               actor: @owner
             )

    on_exit(fn ->
      Auth.cancel(session)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lovelace, key)
        {key, value} -> Application.put_env(:lovelace, key, value)
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

    Lovelace.Owner.issue_session!(Actions.digest(other), DateTime.add(DateTime.utc_now(), 3600),
      actor: %{role: :owner_auth_service}
    )

    assert {:error, :expired} =
             Auth.complete(other, %{"state" => params["state"], "code" => "synthetic_code"})

    assert {:ok, _} =
             Auth.complete(session, %{"state" => params["state"], "code" => "synthetic_code"})

    assert {:error, :expired} =
             Auth.complete(session, %{"state" => params["state"], "code" => "synthetic_code"})

    [
      {:exchange_code, "Iv1.synthetic", "synthetic_client_secret", "synthetic_code", verifier, _}
      | _
    ] = TestGitHub.state().calls

    assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) ==
             params["code_challenge"]

    assert Auth.status(Actions.digest(session)) == %{status: :connected}

    assert %{connections: [_], organizations: owners, memberships: []} =
             Lovelace.GitHub.directory!(actor: @owner)

    assert length(owners) == 2
  end

  test "concurrent callbacks exchange only once and cancellation fences delayed publication", %{
    session: session,
    initial_tokens: initial
  } do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    params = callback_params(session)
    task = Task.async(fn -> Auth.complete(session, params) end)
    assert_receive {:github_waiting, worker}
    assert {:error, :expired} = Auth.complete(session, params)
    assert :ok = Auth.cancel(session)
    assert {:error, :busy} = Auth.begin(session)
    send(worker, :continue)
    assert {:error, _} = Task.await(task)
    assert TestGitHub.state().tokens == initial
    assert Enum.count(TestGitHub.state().calls, &match?({:exchange_code, _, _, _, _, _}, &1)) == 1
  end

  for settlement <- [:completed, :crashed] do
    test "committed authorization rejects queued cancellation after worker #{settlement}", %{
      session: session
    } do
      TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
      params = callback_params(session)
      auth = Process.whereis(Auth)
      callback_ref = make_ref()
      callback = {:complete, %Secret{value: {session, params}}}
      send(auth, {:"$gen_call", {self(), callback_ref}, callback})
      assert_receive {:github_waiting, worker}
      monitor = Process.monitor(worker)
      key = Actions.digest(session)
      attempt = :sys.get_state(Auth)[key]
      parent = self()
      commit = Task.async(fn -> commit_after_signal(auth, attempt.id, session, parent) end)
      assert_receive :github_commit_waiting

      cancel_ref = make_ref()
      send(auth, {:"$gen_call", {self(), cancel_ref}, {:cancel, key}})
      send(auth, :commit)

      assert {:ok, committed} = Task.await(commit)
      assert_receive {^cancel_ref, {:error, :already_authorized}}
      assert_receive {^callback_ref, {:ok, ^committed}}
      assert Auth.status(key) == %{status: :connected}
      assert {:error, :busy} = Auth.begin(session)

      settle_worker(worker, unquote(settlement))
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
      assert :sys.get_state(Auth)[key].worker == nil
      assert Auth.status(key) == %{status: :connected}
      assert {:error, :already_authorized} = Auth.cancel(session)
      refute_receive {^callback_ref, _reply}
      assert %{connections: [connection]} = Lovelace.GitHub.directory!(actor: @owner)
      assert connection.id == committed.connection.id
      assert {:ok, _} = TestGitHubKeychain.get(connection.id)
    end
  end

  test "callback URL requires canonical localhost and preserves the configured port", %{
    session: session
  } do
    config = Application.fetch_env!(:lovelace, Endpoint)
    on_exit(fn -> Endpoint.config_change([{Endpoint, config}], []) end)
    set_endpoint_url(config, host: "localhost", scheme: "http", port: 4323)
    assert Auth.callback_url() == "http://localhost:4323/auth/github/callback"

    for host <- ["127.0.0.1", "::1", "example.invalid"] do
      set_endpoint_url(config, host: host, scheme: "http", port: 4323)
      assert Auth.callback_url() == nil
      assert {:error, :configuration} = Auth.begin(session)
    end

    assert TestGitHub.state().calls == []
  end

  test "revoked sessions refuse exchange commit", %{session: session, initial_tokens: initial} do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    params = callback_params(session)
    task = Task.async(fn -> Auth.complete(session, params) end)
    assert_receive {:github_waiting, worker}
    Lovelace.Owner.logout(session)
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
    task = Task.async(fn -> Auth.complete(session, params) end)
    assert_receive {:github_waiting, worker}
    Vault.lock()
    send(worker, :continue)
    assert {:error, _} = Task.await(task)
    assert TestGitHub.state().tokens == initial
    assert {:error, _} = Lovelace.Owner.verify_session(session)
  end

  test "changing client credentials fences in-flight authorization", %{session: session} do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    params = callback_params(session)
    task = Task.async(fn -> Auth.complete(session, params) end)
    assert_receive {:github_waiting, worker}

    assert {:ok, true} =
             Lovelace.GitHub.save_client_credentials(
               "Iv1.replacement",
               "new_client_secret",
               "replacement-app",
               actor: @owner
             )

    saved = TestGitHub.state().tokens
    send(worker, :continue)
    assert {:error, _} = Task.await(task)
    assert TestGitHub.state().tokens == saved
    assert %{connections: []} = Lovelace.GitHub.directory!(actor: @owner)
  end

  for operation <- [:disconnect_account, :disconnect] do
    test "#{operation} fences an already-running authorization", %{session: session} do
      assert {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())

      TestGitHub.configure(
        exchange_response: {:wait, self(), {:ok, TestGitHub.bundle("replacement")}}
      )

      params = callback_params(session)
      task = Task.async(fn -> Auth.complete(session, params) end)
      assert_receive {:github_waiting, worker}

      id =
        if unquote(operation) == :disconnect_account,
          do: initial.connection.id,
          else: hd(initial.organizations).id

      assert {:ok, _} = apply(Lovelace.GitHub, unquote(operation), [id, [actor: @owner]])
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
    assert {:error, _} = Auth.complete(session, params)
    assert {:error, :expired} = Auth.complete(session, params)

    supervisor =
      if Process.whereis(Lovelace.Security.ProtectedSupervisor),
        do: Lovelace.Security.ProtectedSupervisor,
        else: Lovelace.Supervisor

    :ok = Supervisor.terminate_child(supervisor, Auth)
    {:ok, _} = Supervisor.restart_child(supervisor, Auth)
    assert {:error, :expired} = Auth.complete(session, params)
    assert TestGitHub.state().tokens == initial
  end

  test "expired authorization state never contacts the provider", %{session: session} do
    params = callback_params(session)

    :sys.replace_state(Auth, fn attempts ->
      Map.new(attempts, fn {key, attempt} ->
        {key, %{attempt | expires: System.monotonic_time(:millisecond) - 1}}
      end)
    end)

    assert {:error, :expired} = Auth.complete(session, params)
    assert TestGitHub.state().calls == []
  end

  test "refresh uses the stored client secret and binds the rotated bundle", %{session: session} do
    {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())
    expire(initial.connection.id)
    assert {:ok, "github_access_rotated"} = Operations.access_token(initial.connection.id)

    assert {:refresh_token, "Iv1.synthetic", "synthetic_client_secret", _} =
             Enum.find(TestGitHub.state().calls, &match?({:refresh_token, _, _, _}, &1))

    {:ok, encoded} = TestGitHubKeychain.get(initial.connection.id)
    {:ok, client} = ClientCredentials.current()
    assert Jason.decode!(encoded)["client_generation"] == client.generation
  end

  test "changing clients cannot reuse or refresh the previous app token pair", %{session: session} do
    {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())

    assert {:ok, true} =
             Lovelace.GitHub.save_client_credentials(
               "Iv1.other",
               "other_secret",
               "other-app",
               actor: @owner
             )

    assert {:error, :reconnect} = Operations.access_token(initial.connection.id)
    refute Enum.any?(TestGitHub.state().calls, &match?({:refresh_token, _, _, _}, &1))
    assert %{connections: [account]} = Lovelace.GitHub.directory!(actor: @owner)
    assert account.status == :reauthorization
  end

  test "changing credentials during refresh refuses a delayed rotated pair", %{session: session} do
    {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())
    expire(initial.connection.id)
    TestGitHub.configure(refresh_response: {:wait, self(), {:ok, TestGitHub.bundle("late_pair")}})
    task = Task.async(fn -> Operations.access_token(initial.connection.id) end)
    assert_receive {:github_waiting, worker}

    assert {:ok, true} =
             Lovelace.GitHub.save_client_credentials(
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
    assert {:error, _} = Operations.access_token(initial.connection.id)
    assert {:error, :reconnect} = Operations.access_token(initial.connection.id)
    assert Enum.count(TestGitHub.state().calls, &match?({:refresh_token, _, _, _}, &1)) == 1
  end

  defp commit_after_signal(auth, id, session, parent) do
    commit = %Secret{value: fn -> await_commit_signal(session, parent) end}
    GenServer.call(auth, {:commit, id, commit})
  end

  defp await_commit_signal(session, parent) do
    send(parent, :github_commit_waiting)

    receive do
      :commit -> Operations.authorize(session, TestGitHub.bundle())
    after
      1_000 -> {:error, :test_timeout}
    end
  end

  defp settle_worker(worker, :completed), do: send(worker, :continue)
  defp settle_worker(worker, :crashed), do: Process.exit(worker, :kill)

  defp set_endpoint_url(config, url) do
    Endpoint.config_change([{Endpoint, Keyword.put(config, :url, url)}], [])
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
