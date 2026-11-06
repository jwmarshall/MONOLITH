defmodule Lovelace.ConnectionDiagnosticsTest do
  use Lovelace.DataCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite

  alias Ecto.Adapters.SQL
  alias Lovelace.ConnectionDiagnostics
  alias Lovelace.ConnectionDiagnostics.{State, Worker}
  @owner [actor: %{role: :local_owner}]
  @service %{role: :connection_diagnostics}

  defmodule Keychain do
    def get(_account, _service) do
      send(self(), :diagnostic_read)
      Process.get(:diagnostic_google, {:error, :not_found})
    end

    def get("2fc350e8-33e5-4fd8-9c90-adbb609c742b") do
      send(self(), :diagnostic_read)
      Process.get(:diagnostic_github, {:error, :not_found})
    end

    def get(_account) do
      send(self(), :diagnostic_read)
      Process.get(:diagnostic_gemini, {:error, :not_found})
    end
  end

  setup do
    previous =
      for key <- [:google_client_keychain, :github_keychain, :gemini_vault],
          do: {key, Application.fetch_env(:lovelace, key)}

    for {key, _} <- previous, do: Application.put_env(:lovelace, key, Keychain)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, original} -> Application.put_env(:lovelace, key, original)
          :error -> Application.delete_env(:lovelace, key)
        end
      end
    end)

    :ok
  end

  test "admission authorizes before keychain work, coalesces and stores ID-only jobs" do
    assert {:error, %Ash.Error.Forbidden{}} = ConnectionDiagnostics.request(:google, actor: nil)
    refute_received :diagnostic_read
    assert {:ok, nil} = Ash.get(State, :google, actor: @service, not_found_error?: false)
    assert {:ok, %{id: id, status: :pending}} = ConnectionDiagnostics.request(:google, @owner)
    assert {:ok, %{id: ^id}} = ConnectionDiagnostics.request(:google, @owner)
    assert [job] = all_enqueued(worker: Worker)
    assert job.args == %{"id" => id}
    refute_received :diagnostic_read
    assert :ok = perform_job(Worker, %{id: id})
    assert_received :diagnostic_read

    assert {:ok, %{id: ^id, status: :not_connected}} =
             ConnectionDiagnostics.observe(:google, id, @owner)

    assert :ok = perform_job(Worker, %{id: id})
    refute_received :diagnostic_read
  end

  test "accepted inspection survives the admitting process and rejects non-owner observation" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:accepted, ConnectionDiagnostics.request(:google, @owner)})
      end)

    assert_receive {:accepted, {:ok, %{id: id}}}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert :ok = perform_job(Worker, %{id: id})
    assert {:ok, %{status: :not_connected}} = ConnectionDiagnostics.observe(:google, id, @owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             ConnectionDiagnostics.observe(:google, id, actor: nil)
  end

  test "a terminal job without publication is unavailable, and a fresh request can recover" do
    assert {:ok, %{id: old}} = ConnectionDiagnostics.request(:google, @owner)
    state = Ash.get!(State, :google, actor: @service)
    assert :ok = Oban.cancel_job(state.job_id)
    assert {:ok, %{status: :unavailable}} = ConnectionDiagnostics.observe(:google, old, @owner)
    assert {:ok, %{id: fresh, status: :pending}} = ConnectionDiagnostics.request(:google, @owner)
    refute fresh == old
  end

  test "enqueue failure rolls back the diagnostic intent" do
    SQL.query!(
      Lovelace.Repo,
      "CREATE TEMP TRIGGER reject_diagnostic_job BEFORE INSERT ON oban_jobs BEGIN SELECT RAISE(ABORT, 'synthetic enqueue failure'); END",
      []
    )

    try do
      assert {:error, _} = ConnectionDiagnostics.request(:google, @owner)
      assert Ash.get!(State, :google, actor: @service, not_found_error?: false) == nil
    after
      SQL.query!(Lovelace.Repo, "DROP TRIGGER reject_diagnostic_job", [])
    end

    refute_received :diagnostic_read
  end

  test "status observations recover without PubSub and never expose credentials" do
    secret = "synthetic-do-not-persist-client-secret"

    Process.put(
      :diagnostic_google,
      {:ok, Jason.encode!(%{client_id: "synthetic-id", client_secret: secret})}
    )

    Process.put(:diagnostic_gemini, {:ok, "synthetic-private-gemini-key"})

    Process.put(
      :diagnostic_github,
      {:ok,
       Jason.encode!(%{
         client_id: "synthetic-id",
         client_secret: secret,
         app_slug: "synthetic-app",
         generation: Ash.UUID.generate()
       })}
    )

    for provider <- [:google, :gemini, :github] do
      assert {:ok, %{id: id}} = ConnectionDiagnostics.request(provider, @owner)
      assert :ok = perform_job(Worker, %{id: id})

      assert {:ok, %{status: :stored} = result} =
               ConnectionDiagnostics.observe(provider, id, @owner)

      refute inspect(result) =~ secret
      assert result.app_slug == if(provider == :github, do: "synthetic-app", else: nil)
    end

    assert {:ok, states} = Ash.read(State, actor: @service)
    assert length(states) == 3
    refute inspect(states) =~ secret
    refute inspect(states) =~ "synthetic-private-gemini-key"
  end

  test "missing and malformed GitHub clients expose only safe diagnostic categories" do
    secret = "synthetic-private-client-secret"
    private_slug = "https://private.invalid/apps/private-app?secret=#{secret}"

    for {response, expected} <- [
          {{:error, :not_found}, :not_connected},
          {{:ok,
            Jason.encode!(%{
              client_id: "synthetic-id",
              client_secret: secret,
              app_slug: private_slug,
              generation: Ash.UUID.generate()
            })}, :unavailable},
          {{:ok, "synthetic malformed credential #{secret}"}, :unavailable},
          {{:error, "synthetic native diagnostic #{secret}"}, :unavailable}
        ] do
      Process.put(:diagnostic_github, response)
      ConnectionDiagnostics.serial(:github, fn -> ConnectionDiagnostics.invalidate(:github) end)
      assert {:ok, %{id: id}} = ConnectionDiagnostics.request(:github, @owner)
      assert :ok = perform_job(Worker, %{id: id})
      assert_received :diagnostic_read

      assert {:ok, %{status: ^expected, app_slug: nil} = result} =
               ConnectionDiagnostics.observe(:github, id, @owner)

      state = Ash.get!(State, :github, actor: @service)
      assert state.app_slug == nil
      assert state.status == expected
      refute inspect({result, state, all_enqueued(worker: Worker)}) =~ secret
      refute inspect({result, state}) =~ private_slug
    end
  end

  test "failed result persistence is unavailable without unsafe job errors and a fresh request recovers" do
    secret = "synthetic-private-google-client-secret"

    Process.put(
      :diagnostic_google,
      {:ok, Jason.encode!(%{client_id: "synthetic-id", client_secret: secret})}
    )

    assert {:ok, %{id: rejected}} = ConnectionDiagnostics.request(:google, @owner)
    state = Ash.get!(State, :google, actor: @service)

    SQL.query!(
      Lovelace.Repo,
      "CREATE TEMP TRIGGER reject_diagnostic_result BEFORE UPDATE ON connection_diagnostic_states WHEN NEW.status = 'stored' BEGIN SELECT RAISE(ABORT, 'synthetic private diagnostic persistence failure'); END",
      []
    )

    try do
      assert %{success: 1, failure: 0, discard: 0} =
               Oban.drain_queue(queue: :diagnostics, with_scheduled: true)

      assert_received :diagnostic_read

      assert {:ok, %{status: :unavailable, app_slug: nil} = result} =
               ConnectionDiagnostics.observe(:google, rejected, @owner)

      failed_state = Ash.get!(State, :google, actor: @service)
      refute failed_state.status == :stored
      job = Lovelace.Repo.get!(Oban.Job, state.job_id)
      assert job.state == "completed"
      assert job.errors == []
      refute inspect({result, failed_state, job}) =~ secret

      refute inspect({result, failed_state, job}) =~
               "synthetic private diagnostic persistence failure"
    after
      SQL.query!(Lovelace.Repo, "DROP TRIGGER reject_diagnostic_result", [])
    end

    assert {:ok, %{id: fresh, status: :pending}} = ConnectionDiagnostics.request(:google, @owner)
    refute fresh == rejected

    assert %{success: 1, failure: 0, discard: 0} =
             Oban.drain_queue(queue: :diagnostics, with_scheduled: true)

    assert_received :diagnostic_read
    assert {:ok, %{status: :stored}} = ConnectionDiagnostics.observe(:google, fresh, @owner)

    assert {:ok, %{status: :unavailable}} =
             ConnectionDiagnostics.observe(:google, rejected, @owner)
  end

  test "credential invalidation fences obsolete delivery and superseded observations" do
    assert {:ok, %{id: old}} = ConnectionDiagnostics.request(:google, @owner)

    assert :ok =
             ConnectionDiagnostics.serial(:google, fn ->
               ConnectionDiagnostics.invalidate(:google)
             end)

    assert {:ok, %{id: current}} = ConnectionDiagnostics.request(:google, @owner)
    refute current == old
    assert :ok = perform_job(Worker, %{id: old})
    refute_received :diagnostic_read
    assert {:ok, %{status: :unavailable}} = ConnectionDiagnostics.observe(:google, old, @owner)
    assert {:ok, %{status: :pending}} = ConnectionDiagnostics.observe(:google, current, @owner)
    assert :ok = perform_job(Worker, %{id: current})

    assert {:ok, %{status: :not_connected}} =
             ConnectionDiagnostics.observe(:google, current, @owner)
  end

  test "late state publication cannot overwrite a replaced diagnostic ID" do
    assert {:ok, %{id: old}} = ConnectionDiagnostics.request(:google, @owner)
    state = Ash.get!(State, :google, actor: @service)

    assert :ok =
             ConnectionDiagnostics.serial(:google, fn ->
               ConnectionDiagnostics.invalidate(:google)
             end)

    assert {:error, _} =
             state
             |> Ash.Changeset.for_update(:record, %{expected_id: old, status: :stored},
               actor: @service
             )
             |> Ash.update()

    assert Ash.get!(State, :google, actor: @service).status == :unavailable
  end

  test "native failures are finite safe outcomes, not disconnection or job errors" do
    for {provider, response_key} <- [
          google: :diagnostic_google,
          gemini: :diagnostic_gemini,
          github: :diagnostic_github
        ],
        {response, expected} <- [
          {{:error, :locked}, :locked},
          {{:error, "synthetic locked private diagnostic"}, :unavailable}
        ] do
      Process.put(response_key, response)
      assert {:ok, %{id: id}} = ConnectionDiagnostics.request(provider, @owner)
      assert :ok = perform_job(Worker, %{id: id})
      assert {:ok, %{status: status}} = ConnectionDiagnostics.observe(provider, id, @owner)

      assert status == expected,
             "#{provider} diagnostic must preserve the finite failure category"
    end
  end

  test "expired admitted inspection cannot probe and a fresh request recovers" do
    Process.put(
      :diagnostic_google,
      {:ok, Jason.encode!(%{client_id: "synthetic-id", client_secret: "synthetic-client-secret"})}
    )

    assert {:ok, %{id: id}} = ConnectionDiagnostics.request(:google, @owner)
    state = Ash.get!(State, :google, actor: @service)

    State
    |> Ash.Changeset.for_create(
      :put,
      %{
        provider: :google,
        id: id,
        status: :pending,
        job_id: state.job_id,
        requested_at: DateTime.add(DateTime.utc_now(), -121)
      },
      actor: @service
    )
    |> Ash.create!()

    assert {:ok, %{status: :unavailable}} = ConnectionDiagnostics.observe(:google, id, @owner)
    assert :ok = perform_job(Worker, %{id: id})
    refute_received :diagnostic_read
    assert {:ok, %{status: :unavailable}} = ConnectionDiagnostics.observe(:google, id, @owner)
    assert {:ok, %{id: fresh, status: :pending}} = ConnectionDiagnostics.request(:google, @owner)
    refute fresh == id
    assert Lovelace.Repo.get!(Oban.Job, state.job_id).state == "cancelled"
    assert :ok = perform_job(Worker, %{id: fresh})
    assert_received :diagnostic_read
    assert {:ok, %{status: :stored}} = ConnectionDiagnostics.observe(:google, fresh, @owner)
  end
end
