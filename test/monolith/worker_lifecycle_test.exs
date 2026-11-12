defmodule Monolith.WorkerLifecycleTest.CalendarProvider do
  use Agent

  def start_link(_), do: Agent.start_link(fn -> :ok end, name: __MODULE__)
  def response(value), do: Agent.update(__MODULE__, fn _ -> value end)

  def calendars(token) do
    Monolith.TestMail.record({:worker_calendars, token})

    case Agent.get(__MODULE__, & &1) do
      :ok ->
        {:ok, %{calendars: [%{id: "primary", name: "Primary", selected: true}], truncated: false}}

      :raise ->
        raise "private calendar response"

      :throw ->
        throw(:private_calendar_response)

      other ->
        other
    end
  end

  def events(token, id, _from, _to) do
    Monolith.TestMail.record({:worker_events, token, id})
    today = Date.utc_today()

    {:ok,
     %{
       events: [
         %{
           id: "worker-event",
           title: "Agenda for " <> token,
           start: Date.to_iso8601(today),
           end: today |> Date.add(1) |> Date.to_iso8601(),
           all_day: true,
           url: nil
         }
       ],
       truncated: false
     }}
  end
end

defmodule Monolith.WorkerLifecycleTest.Calendar do
  use Monolith.DataCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite

  alias Monolith.Calendar
  alias Monolith.Calendar.{PollWorker, State}
  alias Monolith.Google.Access
  alias Monolith.WorkerLifecycleTest.CalendarProvider

  @owner %{role: :local_owner}

  setup do
    {:ok, _} = Monolith.TestMail.start()
    start_supervised!(CalendarProvider)
    keys = [:calendar_provider, :gmail_provider, :gmail_vault]
    previous = Map.new(keys, &{&1, Application.fetch_env(:monolith, &1)})
    Application.put_env(:monolith, :calendar_provider, CalendarProvider)
    Application.put_env(:monolith, :gmail_provider, Monolith.TestGoogle)
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailVault)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:monolith, key, value)
          :error -> Application.delete_env(:monolith, key)
        end
      end
    end)

    workspace = Monolith.Workspaces.create_workspace!("Calendar workers", actor: @owner)

    accounts =
      for subject <- ["worker-calendar-a", "worker-calendar-b"] do
        {:ok, account} =
          Access.accept(
            workspace.id,
            %{subject: subject, email: subject <> "@example.invalid"},
            "token-" <> subject,
            :calendar
          )

        account
      end

    date = Date.utc_today()
    from = DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()
    to = DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()
    [a, b] = accounts
    %{a: a, b: b, from: from, to: to, date: Date.to_iso8601(date)}
  end

  test "durable calendar jobs publish only the authorized account's agenda", c do
    a = prepare(c, c.a)
    b = prepare(c, c.b)
    assert {:ok, duplicate} = PollWorker.enqueue(a)
    assert duplicate.conflict?
    assert length(all_enqueued(worker: PollWorker)) == 2
    before = DateTime.utc_now()
    assert :ok = PollWorker.perform(job(a))
    assert [%{title: "Agenda for access:token-worker-calendar-a"}] = snapshot(c, c.a).events
    assert snapshot(c, c.a).fetched_at
    refute snapshot(c, c.a).pending
    assert snapshot(c, c.b).events == []
    assert snapshot(c, c.b).pending
    assert DateTime.compare(state(c.a).next_poll_at, DateTime.add(before, 180)) != :lt
    assert {:worker_calendars, "access:token-worker-calendar-a"} in Monolith.TestMail.calls()
    refute {:worker_calendars, "access:token-worker-calendar-b"} in Monolith.TestMail.calls()
    assert :ok = PollWorker.perform(job(b))
    assert [%{title: "Agenda for access:token-worker-calendar-b"}] = snapshot(c, c.b).events
  end

  test "superseded calendar revisions and disconnected generations cannot republish cached jobs",
       c do
    prepared = prepare(c, c.a)
    assert :ok = PollWorker.perform(job(prepared))
    revised = Calendar.select_calendars!(c.a.id, [], actor: @owner)
    calls = Monolith.TestMail.calls()
    assert :ok = PollWorker.perform(job(prepared))
    assert Monolith.TestMail.calls() == calls
    assert snapshot(c, c.a).events == []
    assert snapshot(c, c.a).pending
    assert :ok = PollWorker.perform(job(%{prepared | revision: revised.revision}))
    refute snapshot(c, c.a).pending
    assert snapshot(c, c.a).selected_ids == []

    assert {:ok, _} = Monolith.Mail.disconnect(c.a.id, actor: @owner)
    calls = Monolith.TestMail.calls()
    assert :ok = PollWorker.perform(job(prepared))
    assert Monolith.TestMail.calls() == calls
    refute snapshot(c, c.a).enabled
    assert snapshot(c, c.a).events == []
  end

  test "provider exceptions and throws preserve the last good agenda and permit later recovery",
       c do
    prepared = prepare(c, c.a)
    assert :ok = PollWorker.perform(job(prepared))
    good = snapshot(c, c.a)

    for response <- [:raise, :throw, :unexpected_provider_reply] do
      CalendarProvider.response(response)
      assert :ok = PollWorker.perform(job(prepared))
      failed = snapshot(c, c.a)
      assert failed.events == good.events
      assert failed.fetched_at == good.fetched_at
      assert failed.error == :provider
      assert failed.stale
      refute failed.pending
      assert Monolith.Mail.get_account!(c.a.id, actor: @owner).last_error == nil
    end

    CalendarProvider.response(:ok)
    assert :ok = PollWorker.perform(job(prepared))
    assert snapshot(c, c.a).error == nil
    refute snapshot(c, c.a).stale
  end

  test "calendar worker rejects malformed durable identity without touching valid agendas", c do
    prepared = prepare(c, c.a)
    assert :ok = PollWorker.perform(job(prepared))
    before = snapshot(c, c.a)
    calls = Monolith.TestMail.calls()
    malformed = put_in(job(prepared).args["account_id"], "not-an-account-uuid")
    assert {:error, :calendar_unavailable} = PollWorker.perform(malformed)
    assert snapshot(c, c.a) == before
    assert Monolith.TestMail.calls() == calls
  end

  defp prepare(c, account) do
    Calendar.prepare!(account.id, c.from, c.to, c.date, "UTC", actor: @owner)
    state(account)
  end

  defp snapshot(c, account),
    do: Calendar.snapshot!(account.id, c.from, c.to, c.date, actor: @owner)

  defp state(account) do
    State
    |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
    |> Ash.read_one!()
  end

  defp job(state) do
    %Oban.Job{
      args: %{
        "account_id" => state.account_id,
        "generation" => state.generation,
        "revision" => state.revision
      }
    }
  end
end

defmodule Monolith.WorkerLifecycleTest.GitHub do
  use Monolith.DataCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite

  alias Ecto.Adapters.SQL.Sandbox
  alias Monolith.GitHub
  alias Monolith.GitHub.{Operations, PollWorker, SweepWorker}
  alias Monolith.Owner.Actions
  alias Monolith.TestGitHub

  @owner %{role: :local_owner}
  @service %{role: :github_service}

  setup do
    start_supervised!({TestGitHub, []})
    keys = [:github_provider, :github_keychain, :github]
    previous = Map.new(keys, &{&1, Application.fetch_env(:monolith, &1)})
    Application.put_env(:monolith, :github_provider, TestGitHub)
    Application.put_env(:monolith, :github_keychain, Monolith.TestGitHubKeychain)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:monolith, key, value)
          :error -> Application.delete_env(:monolith, key)
        end
      end
    end)

    Monolith.Owner.configure!("worker GitHub owner password", actor: %{role: :owner_setup})

    GitHub.save_client_credentials!("Iv1.workers", "worker_client_secret", "worker-app",
      actor: @owner
    )

    session = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Monolith.Owner.issue_session!(
      Actions.digest(session),
      DateTime.add(DateTime.utc_now(), 3600),
      actor: %{role: :owner_auth_service}
    )

    workspace = Monolith.Workspaces.create_workspace!("GitHub workers", actor: @owner)
    %{session: session, workspace: workspace}
  end

  test "restart sweeps schedule only due ready installations and deduplicate unfinished jobs",
       c do
    owners =
      for {login, id} <- Enum.with_index(["overdue", "future", "disconnected", "revoked"], 1) do
        TestGitHub.owner(%{login: login, github_id: "ORG_WORKER_#{id}", installation_id: id})
      end

    TestGitHub.configure(installation_sets: %{"github_access_fake" => owners})
    assert {:ok, _} = Operations.authorize(c.session, TestGitHub.bundle())
    [due, future, disconnected, revoked] = Enum.map(owners, &organization(&1.login))
    update_org(due, %{next_poll_at: DateTime.add(DateTime.utc_now(), -60)})
    update_org(future, %{next_poll_at: DateTime.add(DateTime.utc_now(), 600)})

    update_org(disconnected, %{
      status: :disconnected,
      next_poll_at: DateTime.add(DateTime.utc_now(), -60)
    })

    update_org(revoked, %{
      status: :reauthorization,
      next_poll_at: DateTime.add(DateTime.utc_now(), -60)
    })

    Repo.delete_all(Oban.Job)
    calls = TestGitHub.state().calls
    assert :ok = SweepWorker.perform(%Oban.Job{})
    assert :ok = SweepWorker.perform(%Oban.Job{})
    assert [%Oban.Job{args: args}] = all_enqueued(worker: PollWorker)
    assert args == %{"organization_id" => due.id, "generation" => due.generation}
    assert TestGitHub.state().calls == calls
    assert :ok = PollWorker.perform(%Oban.Job{args: args})
    assert [%{"title" => "Synthetic pull request"}] = organization("overdue").pull_requests
    assert organization("future").pull_requests == []
    assert organization("disconnected").pull_requests == []
    assert organization("revoked").pull_requests == []
    assert organization("overdue").claim_id == nil
    assert DateTime.compare(organization("overdue").next_poll_at, DateTime.utc_now()) == :gt
  end

  test "queued work cannot cross a reauthorization generation or reuse its old credential", c do
    assert {:ok, _} = Operations.authorize(c.session, TestGitHub.bundle())
    old = organization("acme")
    GitHub.attach!(c.workspace.id, old.id, actor: @owner)
    assert :ok = PollWorker.perform(job(old))
    assert organization("acme").fetched_at

    assert {:ok, _} =
             Operations.authorize(c.session, TestGitHub.bundle("replacement-worker-token"))

    current = organization("acme")
    assert current.generation != old.generation
    calls = TestGitHub.state().calls
    assert :ok = PollWorker.perform(job(old))
    assert TestGitHub.state().calls == calls
    assert organization("acme").pull_requests == []
    assert :ok = PollWorker.perform(job(current))

    assert Enum.any?(
             TestGitHub.state().calls,
             &match?({:installation_snapshot, "replacement-worker-token", _}, &1)
           )

    assert organization("acme").fetched_at
    assert organization("synthetic").fetched_at == nil
  end

  test "lost credentials fence every owner for that account before provider polling", c do
    assert {:ok, authorized} = Operations.authorize(c.session, TestGitHub.bundle())
    org = organization("acme")
    assert :ok = PollWorker.perform(job(org))
    org = update_org(organization("acme"), %{next_poll_at: DateTime.add(DateTime.utc_now(), -1)})
    :ok = Monolith.TestGitHubKeychain.delete(authorized.connection.id)
    calls = TestGitHub.state().calls
    assert :ok = PollWorker.perform(job(org))
    assert TestGitHub.state().calls == calls
    directory = GitHub.directory!(actor: @owner)
    assert [%{status: :reauthorization, last_error: :keychain}] = directory.connections

    for current <- directory.organizations do
      assert current.status == :reauthorization
      assert current.last_error == :keychain
      assert current.pull_requests == []
      assert current.claim_id == nil
    end

    Repo.delete_all(Oban.Job)
    assert :ok = SweepWorker.perform(%Oban.Job{})
    assert all_enqueued(worker: PollWorker) == []
  end

  test "expired refresh authorization fences jobs without attempting a refresh or installation read",
       c do
    assert {:ok, authorized} = Operations.authorize(c.session, TestGitHub.bundle())
    org = organization("acme")
    {:ok, encoded} = Monolith.TestGitHubKeychain.get(authorized.connection.id)

    bundle =
      Jason.decode!(encoded) |> Map.put("refresh_expires_at", System.system_time(:second) - 1)

    :ok = Monolith.TestGitHubKeychain.put(authorized.connection.id, Jason.encode!(bundle))
    calls = TestGitHub.state().calls
    assert :ok = PollWorker.perform(job(org))
    assert TestGitHub.state().calls == calls
    assert organization("acme").last_error == :expired
    assert organization("acme").generation != org.generation
    assert organization("acme").status == :reauthorization
  end

  test "unexpected provider replies retain usable snapshots and schedule a later attempt", c do
    assert {:ok, _} = Operations.authorize(c.session, TestGitHub.bundle())
    assert :ok = PollWorker.perform(job(organization("acme")))
    good = organization("acme")
    due = update_org(good, %{next_poll_at: DateTime.add(DateTime.utc_now(), -1)})
    TestGitHub.configure(response: :unexpected_reply)
    assert :ok = PollWorker.perform(job(due))
    failed = organization("acme")
    assert failed.pull_requests == good.pull_requests
    assert failed.fetched_at == good.fetched_at
    assert failed.last_error == :provider
    assert failed.claim_id == nil
    assert failed.claimed_until == nil
    assert DateTime.compare(failed.next_poll_at, DateTime.utc_now()) == :gt
  end

  test "a delayed disconnected account cannot publish into another account's installation", c do
    TestGitHub.configure(
      identities: %{
        "worker-account-a" => %{github_id: "WORKER_USER_A", login: "worker-a"},
        "worker-account-b" => %{github_id: "WORKER_USER_B", login: "worker-b"}
      },
      installation_sets: %{
        "worker-account-a" => [TestGitHub.owner(%{github_id: "WORKER_ORG_A", login: "org-a"})],
        "worker-account-b" => [
          TestGitHub.owner(%{github_id: "WORKER_ORG_B", login: "org-b", installation_id: 2})
        ]
      }
    )

    assert {:ok, a} = Operations.authorize(c.session, TestGitHub.bundle("worker-account-a"))
    assert {:ok, _} = Operations.authorize(c.session, TestGitHub.bundle("worker-account-b"))
    assert :ok = PollWorker.perform(job(organization("org-b")))
    untouched = organization("org-b")
    a_job = job(organization("org-a"))

    response =
      {:ok,
       %{
         pull_requests: [TestGitHub.row(%{"title" => "Late account A result"})],
         repositories: [],
         issues: [],
         workflow_runs: [],
         issue_count: 0,
         issues_truncated: false,
         actions_truncated: false,
         total_count: 1,
         truncated: false,
         partial_reasons: []
       }}

    TestGitHub.configure(response: {:wait, self(), response})

    task =
      Task.async(fn ->
        receive do
          :go -> PollWorker.perform(a_job)
        end
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:github_waiting, provider}, 2000
    assert {:ok, _} = GitHub.disconnect_account(a.connection.id, actor: @owner)
    send(provider, :continue)
    assert :ok = Task.await(task)
    assert organization("org-a").status == :disconnected
    assert organization("org-a").pull_requests == []
    assert organization("org-a").fetched_at == nil
    assert organization("org-b") == untouched

    assert Enum.any?(TestGitHub.state().calls, fn
             {:installation_snapshot, "worker-account-a", %{github_id: "WORKER_ORG_A"}} -> true
             _ -> false
           end)
  end

  test "malformed worker identity is a retryable error without mutating installations", c do
    assert {:ok, _} = Operations.authorize(c.session, TestGitHub.bundle())
    before = GitHub.directory!(actor: @owner)
    calls = TestGitHub.state().calls

    malformed = %Oban.Job{
      args: %{"organization_id" => "invalid-uuid", "generation" => Ash.UUID.generate()}
    }

    assert {:error, :github_unavailable} = PollWorker.perform(malformed)
    assert GitHub.directory!(actor: @owner) == before
    assert TestGitHub.state().calls == calls
  end

  defp organization(login),
    do: Enum.find(GitHub.directory!(actor: @owner).organizations, &(&1.login == login))

  defp update_org(org, attrs),
    do: org |> Ash.Changeset.for_update(:publish, attrs, actor: @service) |> Ash.update!()

  defp job(org),
    do: %Oban.Job{args: %{"organization_id" => org.id, "generation" => org.generation}}
end

defmodule Monolith.WorkerLifecycleTest.Scenery do
  use Monolith.DataCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite

  alias Monolith.Integrations.Gemini.Credentials
  alias Monolith.StageDesigner

  alias Monolith.StageDesigner.{
    Attempt,
    Generation,
    GenerationWorker,
    RecoveryWorker,
    Settings,
    Storage
  }

  alias Monolith.TestSupport.{GeminiVault, PNG, SceneGeneration}

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}

  setup {Req.Test, :verify_on_exit!}

  setup do
    start_supervised!({GeminiVault, []})
    previous = Application.fetch_env(:monolith, :gemini_vault)
    settings = Settings.get()
    directory = Path.join(System.tmp_dir!(), "monolith-worker-scenes-#{Ash.UUID.generate()}")
    Application.put_env(:monolith, :gemini_vault, GeminiVault)
    Application.put_env(:monolith, :stage_designer, %Settings{storage_dir: directory})

    on_exit(fn ->
      Application.put_env(:monolith, :stage_designer, settings)

      case previous do
        {:ok, value} -> Application.put_env(:monolith, :gemini_vault, value)
        :error -> Application.delete_env(:monolith, :gemini_vault)
      end

      File.rm_rf!(directory)
    end)

    :ok
  end

  test "a queued submission with revoked credentials fails once and replay cannot spend fresh consent" do
    attempt = reserve()
    assert :ok = GenerationWorker.perform(job(attempt, "submit"))
    assert current().status == :failed
    assert current().failure =~ "connect Gemini in Settings"
    assert current().provider_id == nil
    assert current().completed_at
    assert StageDesigner.list_scenes!(actor: @owner).eligible
    {:ok, true} = Credentials.save("replacement-fake-key")
    failed = current()
    assert :ok = GenerationWorker.perform(job(attempt, "submit"))
    assert current() == failed
    replacement = reserve()
    assert replacement.id != attempt.id
    assert :ok = GenerationWorker.perform(job(attempt, "submit"))
    assert current().id == replacement.id
    assert current().status == :queued
  end

  test "credential loss pauses tracking without converting a saved provider ID into another submission" do
    attempt = rendering()
    Repo.delete_all(Oban.Job)

    for count <- 1..3 do
      assert :ok = GenerationWorker.perform(job(attempt, "poll"))
      assert current().tracking_errors == count
      assert current().provider_id == attempt.provider_id
    end

    assert current().status == :tracking_paused
    assert StageDesigner.background!().status == :tracking_paused
    refute StageDesigner.list_scenes!(actor: @owner).eligible
    Repo.delete_all(Oban.Job)
    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert all_enqueued(worker: GenerationWorker) == []
    assert {:ok, :scheduled} = StageDesigner.check_scene_attempt(%{id: attempt.id}, actor: @owner)
    assert current().status == :rendering
    assert current().tracking_errors == 0
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "poll"})
    refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})
  end

  test "recovery preserves publication and repairs cleanup intent; failed cleanup remains owner-retryable" do
    attempt = completed()
    published = StageDesigner.get_state!(1, actor: @service)
    assert {:ok, _} = Storage.read(Settings.get(), published.selected_digest)
    Repo.delete_all(Oban.Job)
    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "cleanup"})
    refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})

    assert {:error, :remote_cleanup_unavailable} =
             GenerationWorker.perform(job(attempt, "cleanup"))

    assert current().status == :completed
    assert current().cleanup == :failed
    assert current().cleanup_error =~ "connect Gemini in Settings"

    assert StageDesigner.get_state!(1, actor: @service).selected_digest ==
             published.selected_digest

    assert {:ok, _} = Storage.read(Settings.get(), published.selected_digest)
    Repo.delete_all(Oban.Job)
    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert all_enqueued(worker: GenerationWorker) == []
    assert {:ok, :scheduled} = StageDesigner.check_scene_attempt(%{id: attempt.id}, actor: @owner)
    assert [%Oban.Job{args: %{"operation" => "cleanup"}}] = all_enqueued(worker: GenerationWorker)
  end

  test "recovery requeues only authorized pending work and fences stranded paid submissions" do
    attempt = reserve()
    Repo.delete_all(Oban.Job)
    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})
    assert {:ok, _} = Attempt.record(attempt, %{status: :submitting})
    Repo.delete_all(Oban.Job)
    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert current().status == :submitting
    assert all_enqueued(worker: GenerationWorker) == []
    age_attempts()
    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert current().status == :unknown
    assert StageDesigner.background!().status == :uncertain
    refute StageDesigner.list_scenes!(actor: @owner).eligible
    assert all_enqueued(worker: GenerationWorker) == []
    assert :ok = GenerationWorker.perform(job(attempt, "submit"))
    assert current().status == :unknown
  end

  test "recovery waits for recent tracking and retrieves only the durable ID after a lost job" do
    attempt = rendering()
    Repo.delete_all(Oban.Job)
    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert all_enqueued(worker: GenerationWorker) == []
    age_attempts()
    assert :ok = RecoveryWorker.perform(%Oban.Job{})
    assert [%Oban.Job{args: args}] = all_enqueued(worker: GenerationWorker)
    assert args == %{"id" => attempt.id, "operation" => "poll"}
    assert :ok = GenerationWorker.perform(%Oban.Job{args: args})
    assert current().status == :rendering
    assert current().provider_id == attempt.provider_id
    assert current().tracking_errors == 1
    refute_enqueued(worker: GenerationWorker, args: %{id: attempt.id, operation: "submit"})
  end

  defp reserve do
    assert {:ok, :started} = SceneGeneration.manual()
    current()
  end

  defp rendering do
    attempt = reserve()
    Req.Test.expect(__MODULE__, &SceneGeneration.rendering/1)
    assert :ok = Generation.perform(attempt.id, :submit, SceneGeneration.options(__MODULE__))
    assert current().status == :rendering
    current()
  end

  defp completed do
    attempt = reserve()
    Req.Test.expect(__MODULE__, &SceneGeneration.respond(&1, PNG.image()))
    assert :ok = Generation.perform(attempt.id, :submit, SceneGeneration.options(__MODULE__))
    assert current().status == :completed
    current()
  end

  defp current, do: SceneGeneration.current()

  defp age_attempts do
    Repo.query!("UPDATE stage_designer_attempts SET updated_at = '2000-01-01 00:00:00.000000'")
  end

  defp job(attempt, operation),
    do: %Oban.Job{args: %{"id" => attempt.id, "operation" => operation}}
end
