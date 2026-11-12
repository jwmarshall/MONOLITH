# Separate BEAM: real SQLCipher, Ash authentication, supervision and Oban; synthetic
# native store only. Never starts a real credential helper or provider transport.
import ExUnit.Assertions

Monolith.TestSupport.SubprocessCoverage.start()

alias Monolith.Owner
alias Monolith.Security.{CipherKey, Database, Keychain, Vault}

[root] = System.argv()
File.mkdir_p!(root)
File.chmod!(root, 0o700)

repo = Application.fetch_env!(:monolith, Monolith.Repo)

Application.put_env(
  :monolith,
  Monolith.Repo,
  Keyword.merge(repo, database: Path.join(root, "owner.db"), pool: DBConnection.ConnectionPool)
)

Application.put_env(:monolith, :vault_managed, true)

Application.put_env(:monolith, :stage_designer, %Monolith.StageDesigner.Settings{
  enabled: false,
  storage_dir: Path.join(root, "scenery")
})

Application.put_env(
  :monolith,
  Oban,
  Keyword.merge(Application.fetch_env!(:monolith, Oban),
    testing: :disabled,
    queues: [gmail: 1, gemini: 1],
    plugins: []
  )
)

Application.put_env(
  :monolith,
  MonolithWeb.Endpoint,
  Keyword.merge(Application.fetch_env!(:monolith, MonolithWeb.Endpoint), server: false)
)

defmodule Monolith.SyntheticNativeStore do
  alias Monolith.Security.Keychain
  def configured?, do: File.regular?(Keychain.path())

  def start_link,
    do: Agent.start_link(fn -> %{locked: true, key: nil, password: nil} end, name: __MODULE__)

  def create(password) do
    File.write!(Keychain.path(), "synthetic native store; no real credentials")

    Agent.update(__MODULE__, fn state ->
      %{
        state
        | key: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
          password: password,
          locked: false
      }
    end)

    :ok
  end

  def lock do
    Agent.update(__MODULE__, &%{&1 | locked: true})
    :ok
  end

  def unlock(password) do
    # Like SecKeychainUnlock, an already-unlocked keychain does not authenticate.
    Agent.get_and_update(__MODULE__, fn state ->
      if not state.locked or state.password == password,
        do: {:ok, %{state | locked: false}},
        else: {{:error, :locked}, state}
    end)
  end

  def database_key do
    Agent.get(__MODULE__, fn state ->
      if state.locked, do: {:error, :locked}, else: {:ok, state.key}
    end)
  end

  def status,
    do:
      Agent.get(__MODULE__, fn state -> {:ok, if(state.locked, do: :locked, else: :unlocked)} end)
end

defmodule Monolith.SyntheticVaultHeartbeat do
  use Oban.Worker, queue: :gmail, max_attempts: 1
  @impl true
  def perform(%Oban.Job{args: %{"tag" => tag}}) do
    send(Process.whereis(:monolith_vault_observer), {:heartbeat, tag})
    :ok
  end
end

defmodule Monolith.SyntheticKeychainFailureJob do
  use Oban.Worker, queue: :gmail, max_attempts: 1
  alias Monolith.Security.{Keychain, Vault}

  @impl true
  def perform(%Oban.Job{}) do
    Vault.with_access(fn ->
      send(Process.whereis(:monolith_vault_observer), {:keychain_failure_job, self()})

      Keychain.with_test_runner(
        "get",
        %{account: "01234567-89ab-cdef-0123-456789abcdef", service: "MONOLITH GitHub"},
        fn _ -> {:ok, ~s({"version":1,"error":"locked"}\n)} end
      )
    end)
  end
end

defmodule Monolith.SyntheticVaultShutdownJob do
  use Oban.Worker, queue: :gmail, max_attempts: 1
  @impl true
  def perform(%Oban.Job{}) do
    observer = Process.whereis(:monolith_vault_observer)
    send(observer, {:shutdown_job_started, self()})

    receive do
      :finish ->
        send(observer, :shutdown_job_finished)
        :ok
    end
  end
end

defmodule Monolith.SyntheticGoogleCredentials do
  def read, do: {:ok, %{client_id: "synthetic-client", client_secret: "synthetic-secret"}}
end

defmodule Monolith.SyntheticGoogleTransport do
  @behaviour Monolith.Integrations.Google.Transport
  @impl true
  def request(_request, options) do
    Process.flag(:trap_exit, true)
    observer = Process.whereis(:monolith_vault_observer)
    tag = Keyword.fetch!(options, :tag)
    send(observer, {:google_transport, tag, self()})

    receive do
      :publish ->
        send(observer, {:google_published, tag})

        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(%{access_token: "synthetic-access", expires_in: 3600})
         }}
    end
  end
end

defmodule Monolith.SyntheticGeminiCredentials do
  alias Monolith.Security.Vault

  def get(_account) do
    admission = Vault.track()
    if match?({:ok, _}, admission), do: admission |> elem(1) |> Vault.release()

    send(
      Process.whereis(:monolith_vault_observer),
      {:gemini_credentials, self(), Vault.open?(), admission}
    )

    # Never return a key: this real queued worker must not reach a live transport.
    receive do
      :reject -> {:error, :locked}
    end
  end
end

defmodule Monolith.SyntheticVaultScenario do
  import ExUnit.Assertions

  alias Monolith.Integrations.Google
  alias Monolith.Security.Vault
  alias Monolith.StageDesigner
  alias Monolith.StageDesigner.{Attempt, Generation, GenerationWorker}

  # Recovery also uses :gemini and may have old start observations across Lock.
  # Readiness evidence must identify the actual paid-submission attempt.
  def dispatched(
        _event,
        _measurements,
        %{
          job: %Oban.Job{
            worker: "Monolith.StageDesigner.GenerationWorker",
            args: %{"id" => id, "operation" => "submit"}
          }
        },
        observer
      ),
      do: send(observer, {:gemini_dispatched, id, Vault.open?()})

  def dispatched(_event, _measurements, _metadata, _observer), do: :ok

  def google_request(tag) do
    Application.put_env(:monolith, :gmail,
      timeout_ms: 30_000,
      transport: Monolith.SyntheticGoogleTransport,
      transport_options: [tag: tag]
    )

    observer = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(observer, {:google_finished, tag, exchange()})
    end)
  end

  def exchange do
    Google.exchange_code(
      "synthetic-code",
      String.duplicate("v", 43),
      "http://localhost:4000/oauth/google/callback"
    )
  end

  def pause_gemini do
    :sys.get_state(Vault)
    assert :ok = Oban.pause_queue(queue: :gemini, local_only: true)
    await(fn -> Oban.check_queue(queue: :gemini).paused end)
  end

  def reserve_scene do
    owner = [actor: %{role: :local_owner}]
    choices = %{model: "gemini-nano-banana-2.1", aspect_ratio: "16:9", image_size: "1K"}
    assert {:ok, confirmation} = StageDesigner.prepare_scene_generation(choices, owner)

    assert {:ok, :started} =
             StageDesigner.request_scene_generation(
               %{confirmation: confirmation.confirmation},
               owner
             )

    assert {:ok, %Attempt{status: :queued} = attempt} = Attempt.get(confirmation.id)
    attempt
  end

  def unknown_without_resubmit(id) do
    assert :ok = GenerationWorker.perform(%Oban.Job{args: %{"id" => id, "operation" => "submit"}})
    assert {:ok, %Attempt{status: :unknown, provider_id: nil}} = Attempt.get(id)
    refute_receive {:gemini_credentials, _, _, _}, 100

    assert {:ok, :acknowledged} =
             StageDesigner.acknowledge_scene_attempt(%{id: id}, actor: %{role: :local_owner})
  end

  def blocked_gemini(attempt) do
    observer = self()

    plug = fn conn ->
      Process.flag(:trap_exit, true)
      send(observer, {:gemini_transport, self()})

      receive do
        :publish ->
          send(observer, :gemini_published)
          Req.Test.json(conn, %{id: "synthetic_interaction", status: "in_progress"})
      end
    end

    spawn(fn ->
      Process.flag(:trap_exit, true)

      Vault.with_access(fn ->
        Generation.perform(attempt.id, :submit,
          api_key: "synthetic-gemini-key",
          plug: plug,
          timeout_seconds: 30
        )
      end)
    end)
  end

  def replacement(old) do
    await(fn ->
      case Process.whereis(Vault) do
        pid when is_pid(pid) and pid != old -> pid
        _ -> false
      end
    end)
  end

  def await(fun), do: await(fun, System.monotonic_time(:millisecond) + 20_000)

  defp await(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "vault lifecycle transition timed out"

        Process.sleep(10)
        await(fun, deadline)
    end
  end
end

{:ok, _} = Monolith.SyntheticNativeStore.start_link()
Application.put_env(:monolith, :vault_keychain, Monolith.SyntheticNativeStore)
Application.put_env(:monolith, :google_client_credentials, Monolith.SyntheticGoogleCredentials)
Application.put_env(:monolith, :gemini_vault, Monolith.SyntheticGeminiCredentials)
Process.register(self(), :monolith_vault_observer)
password = "synthetic vault lifecycle owner password"
alias Monolith.SyntheticVaultScenario, as: Scenario
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:oban)

assert :ok =
         :telemetry.attach(
           "synthetic-vault-gemini-admission",
           [:oban, :job, :start],
           &Scenario.dispatched/4,
           self()
         )

# Exercise the browser bootstrap's real default configure callback, not a fake
# owner-creation function. A separate synthetic database preserves the interrupted
# terminal-setup scenario below.
original_repo = Application.fetch_env!(:monolith, Monolith.Repo)

Application.put_env(
  :monolith,
  Monolith.Repo,
  Keyword.put(original_repo, :database, Path.join(root, "bootstrap.db"))
)

{:ok, bootstrap_maintenance} = Vault.start_maintenance()
observer = self()

{:ok, bootstrap} =
  Monolith.Security.Bootstrap.start_link(
    status: &Vault.configuration_status/0,
    announce: fn code -> send(observer, {:browser_pairing, code}) end
  )

assert_receive {:browser_pairing, pairing_code}
assert {:ok, capability} = Monolith.Security.Bootstrap.pair(pairing_code)

assert {:ok, bootstrap_token} =
         Monolith.Security.Bootstrap.configure(capability, password, password, true)

assert {:ok, _} = Owner.verify_session(bootstrap_token)
assert Scenario.await(fn -> is_pid(Oban.Registry.whereis(Oban)) end)
assert Vault.open?()
assert Monolith.Onboarding.pending?()
assert Vault.configuration_status() == :configured
refute Keychain.setup_pending?()

assert {:error, :setup} =
         Monolith.Security.Bootstrap.configure(capability, password, password, true)

refute inspect(:sys.get_status(bootstrap)) =~ password
refute inspect(:sys.get_status(bootstrap)) =~ capability
refute inspect(:sys.get_status(Vault)) =~ password

assert {:error, :already_open} =
         Vault.setup(password, fn -> flunk("cannot replace an open owner") end)

observer = self()

{borrower, borrower_ref} =
  spawn_monitor(fn ->
    assert {:ok, _lease} = Vault.track()
    send(observer, :borrower_admitted)
  end)

assert_receive :borrower_admitted
assert_receive {:DOWN, ^borrower_ref, :process, ^borrower, :normal}
assert Scenario.await(fn -> map_size(:sys.get_state(Vault).leases) == 0 end)
assert {:ok, true} = Vault.lock()
refute Vault.open?()

for authenticate <- [
      fn -> raise "synthetic authentication storage failure" end,
      fn -> throw(:synthetic_authentication_failure) end
    ] do
  assert {:error, _} = Vault.unlock(password, authenticate, maintenance: true)
  refute Vault.open?()
  assert Process.whereis(Monolith.Repo) == nil
  assert {:ok, :locked} = Monolith.SyntheticNativeStore.status()
end

GenServer.stop(bootstrap)
Supervisor.stop(bootstrap_maintenance)
Application.put_env(:monolith, Monolith.Repo, original_repo)

assert :ok = Keychain.begin_setup()
{:ok, maintenance} = Vault.start_maintenance()

assert {:ok, _} =
         Vault.setup(password, fn -> Owner.Actions.configure_or_authenticate(password) end)

assert {:ok, original_credential} = Owner.read_credential(actor: %{role: :owner_auth_service})
assert {:ok, true} = Vault.lock()
Supervisor.stop(maintenance)

# An interrupted terminal setup after owner creation remains resumable, without
# changing the password hash or allowing an ordinary application unlock.
assert Vault.configuration_status() == :setup_incomplete
{:ok, maintenance} = Vault.start_maintenance()

assert {:error, _} =
         Vault.setup("incorrect", fn -> Owner.Actions.configure_or_authenticate("incorrect") end)

refute Vault.open?()

assert {:ok, _} =
         Vault.setup(password, fn -> Owner.Actions.configure_or_authenticate(password) end)

assert {:ok, resumed_credential} = Owner.read_credential(actor: %{role: :owner_auth_service})
assert resumed_credential.hashed_password == original_credential.hashed_password
assert {:ok, database_key} = Monolith.SyntheticNativeStore.database_key()
assert {:ok, true} = Vault.lock()
assert :ok = Keychain.finish_setup()
Supervisor.stop(maintenance)
assert Vault.configuration_status() == :configured

{:ok, _} = Application.ensure_all_started(:monolith)
refute Vault.open?()
assert is_nil(Process.whereis(Monolith.Repo))
assert is_nil(Oban.Registry.whereis(Oban))
assert {:ok, :locked} = Monolith.SyntheticNativeStore.status()

# A valid cipher with an unusable owner schema must fail before authentication
# or background activation, then close Repo and the native store.
mutate_schema = fn sql ->
  {:ok, handle} = Exqlite.Sqlite3.open(Path.join(root, "owner.db"))

  try do
    assert :ok = Exqlite.Sqlite3.execute(handle, "PRAGMA key = #{CipherKey.new!(database_key)}")
    assert :ok = Exqlite.Sqlite3.execute(handle, sql)
  after
    Exqlite.Sqlite3.close(handle)
  end
end

mutate_schema.("ALTER TABLE owner_sessions RENAME TO synthetic_unavailable_sessions")
observer = self()

assert {:error, :unlock_unavailable} =
         Vault.unlock(password, fn ->
           send(observer, :broken_schema_authentication)
           {:ok, :unexpected}
         end)

refute_receive :broken_schema_authentication
refute Vault.open?()
assert is_nil(Process.whereis(Monolith.Repo))
assert is_nil(Oban.Registry.whereis(Oban))
assert {:ok, :locked} = Monolith.SyntheticNativeStore.status()
mutate_schema.("ALTER TABLE synthetic_unavailable_sessions RENAME TO owner_sessions")
assert {:error, _} = Owner.unlock("incorrect", "wrong-locked")
assert is_nil(Process.whereis(Monolith.Repo))
assert {:ok, first} = Owner.unlock(password, "first-unlock")
assert Vault.open?()
assert :ok = Database.validate()
assert {:ok, _} = Owner.verify_session(first)
assert {:error, _} = Owner.unlock("incorrect", "wrong-open")
assert {:ok, _} = Owner.verify_session(first)
assert {:error, :vault_in_use} = Database.acquire_runtime_lock()
assert {:ok, first} = Monolith.TestSupport.VaultHTTPScenario.run(first, password: password)

assert {:ok, first} =
         Monolith.TestSupport.VaultHTTPScenario.run(first,
           password: password,
           generated_image: true
         )

# A real queue reads/writes the encrypted database while no browser is active.
assert Scenario.await(fn -> is_pid(Oban.Registry.whereis(Oban)) end)

{:ok, _} =
  %{tag: "unlocked-background"} |> Monolith.SyntheticVaultHeartbeat.new() |> Oban.insert()

assert_receive {:heartbeat, "unlocked-background"}, 10_000

# A restarted queue must retain ordinary dispatch while the vault remains open,
# without another unlock or an initial-readiness bypass.
producer = Oban.Registry.whereis(Oban, {:producer, "gmail"})
assert is_pid(producer)
producer_ref = Process.monitor(producer)
Process.exit(producer, :kill)
assert_receive {:DOWN, ^producer_ref, :process, ^producer, :killed}

Scenario.await(fn ->
  current = Oban.Registry.whereis(Oban, {:producer, "gmail"})
  is_pid(current) and current != producer
end)

assert Vault.open?()
{:ok, _} = %{tag: "producer-restarted"} |> Monolith.SyntheticVaultHeartbeat.new() |> Oban.insert()
assert_receive {:heartbeat, "producer-restarted"}, 10_000

old_expiry = :sys.get_state(Vault).timer |> elem(1)
assert {:ok, second} = Owner.unlock(password, "second-unlock")
send(Vault, {:expire, old_expiry})
:sys.get_state(Vault)
assert {:ok, _} = Owner.verify_session(second)

parent = self()

reader =
  spawn(fn ->
    Vault.with_access(fn ->
      send(parent, :reader_admitted)

      receive do
        :release -> :ok
      end
    end)
  end)

monitor = Process.monitor(reader)
assert_receive :reader_admitted
assert {:ok, true} = Owner.lock_all(actor: %{role: :local_owner})
assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}
refute Vault.open?()
assert is_nil(Process.whereis(Monolith.Repo))
assert is_nil(Oban.Registry.whereis(Oban))
assert {:ok, :locked} = Monolith.SyntheticNativeStore.status()
assert {:error, :locked} = Vault.with_access(fn -> flunk("locked work was admitted") end)
assert {:error, _} = Owner.verify_session(first)
assert {:error, _} = Owner.verify_session(second)

assert {:ok, reopened} = Owner.unlock(password, "reopen")
assert {:error, _} = Owner.verify_session(first)
assert {:error, _} = Owner.verify_session(second)
assert {:ok, _} = Owner.verify_session(reopened)
{:ok, _} = %{tag: "resumed-background"} |> Monolith.SyntheticVaultHeartbeat.new() |> Oban.insert()
assert_receive {:heartbeat, "resumed-background"}, 10_000

expiry = :sys.get_state(Vault).timer |> elem(1)
send(Vault, {:expire, expiry})
:sys.get_state(Vault)
refute Vault.open?()
assert is_nil(Process.whereis(Monolith.Repo))
assert {:error, _} = Owner.verify_session(reopened)

assert {:ok, _} = Owner.unlock(password, "before-provider-fences")

# Exercise Google's actual bounded worker with synthetic credentials and a
# blocked fake transport that deliberately traps linked process exits.
Scenario.google_request(:explicit_lock)
assert_receive {:google_transport, :explicit_lock, google}, 10_000
google_ref = Process.monitor(google)
assert {:ok, true} = Owner.lock_all(actor: %{role: :local_owner})
refute Process.alive?(google)
assert_receive {:DOWN, ^google_ref, :process, ^google, :killed}
send(google, :publish)
refute_receive {:google_published, :explicit_lock}, 100
assert {:error, :locked} = Scenario.exchange()
refute_receive {:google_transport, _, _}, 100
assert {:ok, _} = Owner.unlock(password, "after-google-lock")

# Missing optional credentials and invalid local input do not imply lost
# keychain authorization, and must not log the owner out.
keychain_attributes = %{
  account: "01234567-89ab-cdef-0123-456789abcdef",
  service: "MONOLITH Gmail"
}

assert {:error, :not_found} =
         Keychain.with_test_runner("get", keychain_attributes, fn _ ->
           {:ok, ~s({"version":1,"error":"not_found"}\n)}
         end)

assert {:error, :invalid_account} =
         Keychain.with_test_runner(
           "get",
           %{keychain_attributes | account: "invalid"},
           fn _ -> flunk("invalid account reached native keychain") end
         )

assert {:ok, :unlocked} =
         Keychain.with_test_runner("status", %{}, fn _ ->
           {:ok, ~s({"version":1,"ok":true,"status":"unlocked"}\n)}
         end)

assert Vault.open?()

# A credential-storage failure must globally lock even when reported by a
# protected queue worker. Do not synchronously stop a worker awaiting Vault.
assert {:ok, before_keychain_failure} = Owner.unlock(password, "before-keychain-failure")

keychain_session_topic =
  before_keychain_failure |> Owner.Actions.digest() |> Owner.Actions.topic()

Phoenix.PubSub.subscribe(Monolith.PubSub, keychain_session_topic)
observer = self()

{owner_view, owner_view_ref} =
  spawn_monitor(fn ->
    socket = %Phoenix.LiveView.Socket{
      endpoint: MonolithWeb.Endpoint,
      router: MonolithWeb.Router,
      transport_pid: self(),
      assigns: %{__changed__: %{}},
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }

    assert {:cont, _} =
             MonolithWeb.OwnerAuth.on_mount(
               :require_owner,
               %{},
               %{"owner_session_token" => before_keychain_failure},
               socket
             )

    send(observer, :connected_owner_admitted)

    receive do
      :continue -> flunk("connected owner survived global Lock")
    end
  end)

assert_receive :connected_owner_admitted
Scenario.google_request(:keychain_failure)
assert_receive {:google_transport, :keychain_failure, keychain_google}, 10_000
keychain_google_ref = Process.monitor(keychain_google)
assert {:ok, _} = %{} |> Monolith.SyntheticKeychainFailureJob.new() |> Oban.insert()
assert_receive {:keychain_failure_job, _}, 10_000
assert Scenario.await(fn -> not Vault.open?() end)
assert %{mode: :locked, runtime: nil} = :sys.get_state(Vault, 25_000)
assert_receive {:DOWN, ^keychain_google_ref, :process, ^keychain_google, :killed}
assert_receive {:DOWN, ^owner_view_ref, :process, ^owner_view, :killed}
assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^keychain_session_topic}
Phoenix.PubSub.unsubscribe(Monolith.PubSub, keychain_session_topic)
assert is_nil(Process.whereis(Monolith.Repo))
assert is_nil(Oban.Registry.whereis(Oban))
assert {:ok, :locked} = Monolith.SyntheticNativeStore.status()
assert {:error, :locked} = Scenario.exchange()
send(keychain_google, :publish)
refute_receive {:google_published, :keychain_failure}, 100
assert {:ok, _} = Owner.unlock(password, "after-keychain-failure")
assert {:error, _} = Owner.verify_session(before_keychain_failure)

# All credential operations share the same native failure boundary. Lost
# authorization, storage loss, timeout and malformed helper output fail closed.
authenticate_owner = fn -> Owner.Actions.configure_or_authenticate(password) end

for {operation, attributes, output, expected} <- [
      {"get", keychain_attributes, ~s({"version":1,"error":"unavailable"}\n),
       {:error, :unavailable}},
      {"get", keychain_attributes, ~s({"version":1,"error":"timeout"}\n), {:error, :timeout}},
      {"get", keychain_attributes, ~s({"version":1,"error":"missing"}\n), {:error, :missing}},
      {"get", keychain_attributes, "invalid native response\n", {:error, :unavailable}},
      {"put", Map.put(keychain_attributes, :value, "synthetic-value"),
       ~s({"version":1,"error":"locked"}\n), {:error, :locked}},
      {"delete", keychain_attributes, ~s({"version":1,"error":"unavailable"}\n),
       {:error, :unavailable}},
      {"status", %{}, ~s({"version":1,"ok":true,"status":"locked"}\n), {:ok, :locked}}
    ] do
  assert {:ok, previous_session} = Vault.unlock(password, authenticate_owner)
  session_topic = previous_session |> Owner.Actions.digest() |> Owner.Actions.topic()
  Phoenix.PubSub.subscribe(Monolith.PubSub, session_topic)
  assert ^expected = Keychain.with_test_runner(operation, attributes, fn _ -> {:ok, output} end)
  refute Vault.open?()
  assert %{mode: :locked, runtime: nil} = :sys.get_state(Vault, 25_000)
  assert is_nil(Process.whereis(Monolith.Repo))
  assert is_nil(Oban.Registry.whereis(Oban))
  assert {:ok, :locked} = Monolith.SyntheticNativeStore.status()
  assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^session_topic}
  Phoenix.PubSub.unsubscribe(Monolith.PubSub, session_topic)
  assert {:ok, _} = Vault.unlock(password, authenticate_owner)
  assert {:error, _} = Owner.verify_session(previous_session)
end

# An ungated native reporter may itself belong to protected supervision. Its
# reply must not wait on teardown of its own supervisor or unrelated queue work.
assert Scenario.await(fn -> is_pid(Oban.Registry.whereis(Oban)) end)
assert {:ok, _} = %{} |> Monolith.SyntheticVaultShutdownJob.new() |> Oban.insert()
assert_receive {:shutdown_job_started, draining_job}, 10_000
observer = self()

assert {:ok, _} =
         Supervisor.start_child(
           Monolith.Security.ProtectedSupervisor,
           %{
             id: :keychain_failure_reporter,
             restart: :temporary,
             start:
               {Task, :start_link,
                [
                  fn ->
                    Process.flag(:trap_exit, true)

                    result =
                      Keychain.with_test_runner("get", keychain_attributes, fn _ ->
                        {:ok, ~s({"version":1,"error":"locked"}\n)}
                      end)

                    send(observer, {:protected_native_result, result})
                  end
                ]}
           }
         )

assert_receive {:protected_native_result, {:error, :locked}}, 5_000
refute Vault.open?()
assert Process.alive?(draining_job)
send(draining_job, :finish)
assert_receive :shutdown_job_finished, 10_000
assert %{mode: :locked, runtime: nil} = :sys.get_state(Vault, 25_000)
assert {:ok, _} = Vault.unlock(password, authenticate_owner)

# Reauthentication can read the keychain inside the Vault process itself;
# a failure must not attempt a synchronous call to that same GenServer.
assert {:error, _} =
         Vault.unlock(password, fn ->
           Keychain.with_test_runner("get", keychain_attributes, fn _ ->
             {:ok, ~s({"version":1,"error":"locked"}\n)}
           end)
         end)

refute Vault.open?()
assert %{mode: :locked, runtime: nil} = :sys.get_state(Vault, 25_000)
assert {:ok, _} = Owner.unlock(password, "after-vault-owned-keychain-failure")

# An ungated infrastructure read from a retired epoch may finish after another
# unlock. Its delayed failure must not lock the replacement runtime.
observer = self()

{stale_reader, stale_reader_ref} =
  spawn_monitor(fn ->
    result =
      Keychain.with_test_runner("get", keychain_attributes, fn _ ->
        send(observer, {:stale_keychain_read, self()})

        receive do
          :finish -> {:ok, ~s({"version":1,"error":"unavailable"}\n)}
        end
      end)

    send(observer, {:stale_keychain_result, result})
  end)

assert_receive {:stale_keychain_read, stale_native}
assert {:ok, true} = Vault.lock()
assert {:ok, replacement_session} = Owner.unlock(password, "before-delayed-keychain-failure")
send(stale_native, :finish)
assert_receive {:stale_keychain_result, {:error, :unavailable}}
assert_receive {:DOWN, ^stale_reader_ref, :process, ^stale_reader, :normal}
assert Vault.open?()
assert {:ok, _} = Owner.verify_session(replacement_session)

# A ready, previously authorized Gemini job survives locked admission without
# claiming its paid submission. On unlock the real queue reaches credential
# acquisition only after the manager can service its leases.
Scenario.pause_gemini()
queued = Scenario.reserve_scene()
assert {:ok, true} = Vault.lock()

assert {:snooze, 1} =
         Monolith.StageDesigner.GenerationWorker.perform(%Oban.Job{
           args: %{"id" => queued.id, "operation" => "submit"}
         })

assert {:ok, _} = Owner.unlock(password, "queued-gemini-readiness")
queued_id = queued.id
assert_receive {:gemini_dispatched, ^queued_id, admission_open?}, 10_000
assert admission_open?
assert_receive {:gemini_credentials, gemini_job, true, {:ok, _}}, 10_000
gemini_job_ref = Process.monitor(gemini_job)
assert {:ok, %{status: :submitting}} = Monolith.StageDesigner.Attempt.get(queued.id)
assert {:ok, true} = Vault.lock()
refute Process.alive?(gemini_job)
assert_receive {:DOWN, ^gemini_job_ref, :process, ^gemini_job, :killed}
assert {:ok, _} = Owner.unlock(password, "after-queued-gemini")
Scenario.unknown_without_resubmit(queued.id)

# Follow real Ash reservation -> permanent submission claim -> Interactions ->
# Req fake HTTP. Both the operation and trapping HTTP task must die before lock
# acknowledges; replay may record unknown, never another paid POST.
Scenario.pause_gemini()
attempt = Scenario.reserve_scene()
gemini_operation = Scenario.blocked_gemini(attempt)
gemini_operation_ref = Process.monitor(gemini_operation)
assert_receive {:gemini_transport, gemini_http}, 10_000
gemini_http_ref = Process.monitor(gemini_http)
assert {:ok, true} = Vault.lock()
refute Process.alive?(gemini_operation)
refute Process.alive?(gemini_http)
assert_receive {:DOWN, ^gemini_operation_ref, :process, ^gemini_operation, :killed}
assert_receive {:DOWN, ^gemini_http_ref, :process, ^gemini_http, :killed}
send(gemini_http, :publish)
refute_receive :gemini_published, 100
assert {:ok, _} = Owner.unlock(password, "after-gemini-http")
Scenario.unknown_without_resubmit(attempt.id)

# Abrupt manager death cannot strand independent/trapping consumers. Keep an
# actual Oban job running during old-runtime teardown to prove the native
# exclusion remains pinned until that runtime, not merely the manager, is gone.
{:ok, _} = %{} |> Monolith.SyntheticVaultShutdownJob.new() |> Oban.insert()
assert_receive {:shutdown_job_started, old_job}, 10_000
Scenario.google_request(:manager_restart)
assert_receive {:google_transport, :manager_restart, old_google}, 10_000
old_google_ref = Process.monitor(old_google)
observer = self()

holder =
  spawn(fn ->
    Process.flag(:trap_exit, true)

    Vault.with_access(fn ->
      send(observer, :trapping_holder_admitted)

      receive do
        :publish -> send(observer, :stale_holder_published)
      end
    end)
  end)

holder_ref = Process.monitor(holder)
assert_receive :trapping_holder_admitted
old_manager = Process.whereis(Vault)
manager_ref = Process.monitor(old_manager)
Process.exit(old_manager, :kill)
assert_receive {:DOWN, ^manager_ref, :process, ^old_manager, :killed}
assert_receive {:DOWN, ^old_google_ref, :process, ^old_google, :killed}, 5_000
assert_receive {:DOWN, ^holder_ref, :process, ^holder, :killed}, 5_000
assert Process.alive?(old_job)
assert {:error, :vault_in_use} = Database.acquire_runtime_lock()
send(old_job, :finish)
assert_receive :shutdown_job_finished, 10_000
replacement = Scenario.replacement(old_manager)
assert %{mode: :locked, runtime: nil} = :sys.get_state(replacement, 25_000)
assert {:ok, :locked} = Monolith.SyntheticNativeStore.status()
assert is_nil(Process.whereis(Monolith.Repo))
assert is_nil(Oban.Registry.whereis(Oban))
send(old_google, :publish)
send(holder, :publish)
assert {:ok, before_restart} = Owner.unlock(password, "after-abrupt-manager-restart")
refute_receive {:google_published, :manager_restart}, 100
refute_receive :stale_holder_published, 100

# Ordinary Application.stop must not impose GenServer's default five-second
# shutdown on the manager while Oban is honoring its fifteen-second job drain.
{:ok, _} = %{} |> Monolith.SyntheticVaultShutdownJob.new() |> Oban.insert()
assert_receive {:shutdown_job_started, shutdown_job}, 10_000
shutdown_started = System.monotonic_time(:millisecond)
observer = self()
spawn(fn -> send(observer, {:application_stopped, Application.stop(:monolith)}) end)
Process.sleep(6_000)
assert Process.alive?(shutdown_job)
refute_receive {:application_stopped, _}, 0
assert {:ok, :unlocked} = Monolith.SyntheticNativeStore.status()
send(shutdown_job, :finish)
assert_receive :shutdown_job_finished, 10_000
assert_receive {:application_stopped, :ok}, 10_000
assert System.monotonic_time(:millisecond) - shutdown_started >= 6_000
assert {:ok, :locked} = Monolith.SyntheticNativeStore.status()
{:ok, _} = Application.ensure_all_started(:monolith)
refute Vault.open?()
assert is_nil(Process.whereis(Monolith.Repo))
assert is_nil(Oban.Registry.whereis(Oban))
assert {:ok, :locked} = Monolith.SyntheticNativeStore.status()
assert {:ok, final} = Owner.unlock(password, "after-restart")
assert {:error, _} = Owner.verify_session(before_restart)
assert {:ok, _} = Owner.verify_session(final)
assert {:ok, true} = Vault.lock()
:ok = Application.stop(:monolith)
refute File.read!(Path.join(root, "owner.db")) =~ "SQLite format 3"
refute File.read!(Keychain.path()) =~ password

IO.puts(
  "Vault lifecycle: setup recovery, failed schema, keychain autolock and epoch fencing, HTTP/provider fencing, queue admission, shutdown drain, restart and ciphertext verified"
)
