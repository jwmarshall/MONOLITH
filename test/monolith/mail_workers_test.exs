defmodule Monolith.MailWorkersTest do
  use Monolith.DataCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite

  alias Ecto.Adapters.SQL.Sandbox
  alias Monolith.Google.Access
  alias Monolith.Mail
  alias Monolith.Mail.{CacheEntry, PollWorker, SweepWorker}

  @owner %{role: :local_owner}

  setup do
    {:ok, _} = Monolith.TestMail.start()
    previous = Keyword.take(Application.get_all_env(:monolith), [:gmail_provider, :gmail_vault])
    Application.put_env(:monolith, :gmail_provider, Monolith.TestGoogle)
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailVault)

    on_exit(fn ->
      for key <- [:gmail_provider, :gmail_vault] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:monolith, key, value)
          :error -> Application.delete_env(:monolith, key)
        end
      end
    end)

    workspace = Monolith.Workspaces.create_workspace!("Worker fixture", actor: @owner)
    a = connect(workspace, "worker-a")
    b = connect(workspace, "worker-b")
    %{workspace: workspace, a: a, b: b}
  end

  test "sweep enqueues only overdue ready accounts with identity-only args", %{
    workspace: workspace,
    a: overdue,
    b: future
  } do
    reconnect = connect(workspace, "worker-reconnect")
    disconnected = connect(workspace, "worker-disconnected")
    now = DateTime.utc_now()
    set_status(overdue, %{next_poll_at: DateTime.add(now, -60)})
    set_status(future, %{next_poll_at: DateTime.add(now, 600)})
    set_status(reconnect, %{status: :reconnect, next_poll_at: DateTime.add(now, -60)})
    set_status(disconnected, %{status: :disconnected, next_poll_at: DateTime.add(now, -60)})
    Repo.delete_all(Oban.Job)

    assert :ok = SweepWorker.perform(%Oban.Job{args: %{}})
    assert [%Oban.Job{args: args}] = all_enqueued(worker: PollWorker)
    assert args == %{"account_id" => overdue.id, "generation" => overdue.generation}
    assert Monolith.TestMail.calls() == []
  end

  test "poll worker publishes and caches only its account; stale generation does no work", %{
    a: a,
    b: b
  } do
    observe("mail:#{a.id}", :account_a)
    observe("mail:#{b.id}", :account_b)

    assert :ok = PollWorker.perform(job(a))
    assert_receive {:account_a, {:mail_changed, id}}
    assert id == a.id
    refute_receive {:account_b, _}
    assert [entry] = entries(a)
    assert entry.account_id == a.id
    assert entry.generation == a.generation
    assert hd(entry.payload["threads"])["subject"] == "access:token-worker-a"
    assert entries(b) == []
    assert Mail.get_account!(a.id, actor: @owner).last_success_at
    assert Mail.get_account!(b.id, actor: @owner).last_success_at == nil

    current =
      Mail.save_connection!(
        %{id: a.id, subject: a.subject, email: a.email, generation: Ash.UUID.generate()},
        actor: @owner
      )

    calls = Monolith.TestMail.calls()
    assert :ok = PollWorker.perform(job(a))
    assert Monolith.TestMail.calls() == calls
    assert Mail.get_account!(a.id, actor: @owner).generation == current.generation
    refute_receive {:account_a, _}
    refute_receive {:account_b, _}
  end

  test "transient failures return a retryable worker error without touching another account", %{
    a: a,
    b: b
  } do
    Monolith.TestMail.response({:error, :offline})
    assert {:error, :mail_unavailable} = PollWorker.perform(job(a))
    assert Mail.get_account!(a.id, actor: @owner).last_error == :unavailable
    assert Mail.get_account!(b.id, actor: @owner).last_error == nil
    assert entries(a) == []
  end

  test "rate limit is terminal for the job and persisted cooldown denies queued and manual work",
       %{
         workspace: workspace,
         a: a
       } do
    assert :ok = PollWorker.perform(job(a))
    Monolith.TestMail.response({:error, :rate_limited})
    before = DateTime.utc_now()
    assert :ok = PollWorker.perform(job(a))
    after_request = DateTime.utc_now()
    limited = Mail.get_account!(a.id, actor: @owner)
    assert limited.last_error == :rate_limited
    assert DateTime.compare(limited.next_poll_at, DateTime.add(before, 300)) != :lt
    assert DateTime.compare(limited.next_poll_at, DateTime.add(after_request, 300)) != :gt
    calls = Monolith.TestMail.calls()
    Monolith.TestMail.response(:ok)

    for _ <- 1..3 do
      assert :ok = PollWorker.perform(job(a))

      assert {:ok, %{error: :rate_limited, stale: true}} =
               Mail.mail_page(workspace.id, a.id, actor: @owner)

      assert {:ok, %{error: :rate_limited, stale: true}} =
               Mail.mail_page(workspace.id, a.id, %{force: true}, actor: @owner)

      assert {:ok, %{data: nil, error: :rate_limited, stale: true}} =
               Mail.thread(workspace.id, a.id, "uncached-thread", %{force: true}, actor: @owner)
    end

    assert Monolith.TestMail.calls() == calls
    assert Mail.get_account!(a.id, actor: @owner).next_poll_at == limited.next_poll_at
    assert :ok = SweepWorker.perform(%Oban.Job{args: %{}})
    assert Mail.get_account!(a.id, actor: @owner).next_poll_at == limited.next_poll_at
  end

  test "expired cache reopen retains persisted rate-limit error without provider calls", %{
    workspace: workspace,
    a: a
  } do
    assert :ok = PollWorker.perform(job(a))
    assert [entry] = entries(a)
    now = DateTime.utc_now()

    CacheEntry
    |> Ash.Changeset.for_create(
      :store,
      %{
        account_id: a.id,
        key: entry.key,
        generation: a.generation,
        payload: entry.payload,
        bytes: entry.bytes,
        fetched_at: DateTime.add(now, -700_000),
        expires_at: DateTime.add(now, -1)
      },
      actor: @owner
    )
    |> Ash.create!()

    deadline = DateTime.add(now, 300)
    set_status(a, %{last_error: :rate_limited, next_poll_at: deadline})
    calls = Monolith.TestMail.calls()

    assert {:ok, %{data: nil, error: :rate_limited, stale: true}} =
             Mail.mail_page(workspace.id, a.id, actor: @owner)

    assert entries(a) == []
    assert Monolith.TestMail.calls() == calls
    assert Mail.get_account!(a.id, actor: @owner).next_poll_at == deadline
  end

  test "token admission refusal is distinct from a new provider rate limit", %{a: a} do
    deadline = DateTime.add(DateTime.utc_now(), 300)
    limited = set_status(a, %{last_error: :rate_limited, next_poll_at: deadline})
    assert {:error, :cooldown} = Access.access_token(limited)
    assert Monolith.TestMail.calls() == []
    assert Mail.get_account!(a.id, actor: @owner).next_poll_at == deadline
  end

  test "an admission refusal handled after expiry cannot start another cooldown", %{
    workspace: workspace,
    a: a
  } do
    expired =
      set_status(a, %{
        last_error: :rate_limited,
        next_poll_at: DateTime.add(DateTime.utc_now(), -1)
      })

    # Inject only the internal admission result at the async boundary. Unlike an
    # actual provider :rate_limited response, this must never persist failure.
    Monolith.TestMail.response({:error, :cooldown})

    assert %{error: :rate_limited} =
             Mail.mail_page!(workspace.id, a.id, %{force: true}, actor: @owner)

    assert Mail.get_account!(a.id, actor: @owner) == expired
    refute Enum.any?(Monolith.TestMail.calls(), &match?({:page, _, _, _}, &1))
  end

  test "ordinary scheduled polling deadline does not deny an explicit Refresh", %{
    workspace: workspace,
    a: a
  } do
    set_status(a, %{last_error: nil, next_poll_at: DateTime.add(DateTime.utc_now(), 600)})

    assert {:ok, %{error: nil, cached: false}} =
             Mail.mail_page(workspace.id, a.id, %{force: true}, actor: @owner)

    assert {:refresh, "token-worker-a"} in Monolith.TestMail.calls()
  end

  test "success already in flight cannot clear a concurrent persisted rate cooldown", %{
    workspace: workspace,
    a: a
  } do
    Monolith.TestMail.response({:wait_thread, self()})

    task =
      Task.async(fn ->
        receive do
          :go -> Mail.thread(workspace.id, a.id, "in-flight", actor: @owner)
        end
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:thread_waiting, provider}, 2000
    Monolith.TestMail.response({:error, :rate_limited})
    assert :ok = PollWorker.perform(job(a))
    limited = Mail.get_account!(a.id, actor: @owner)
    send(provider, :continue)
    assert {:ok, _} = Task.await(task)
    current = Mail.get_account!(a.id, actor: @owner)
    assert current.last_error == :rate_limited
    assert current.next_poll_at == limited.next_poll_at
  end

  defp observe(topic, tag) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(Monolith.PubSub, topic)
        send(parent, {:subscribed, self()})
        forward_events(parent, tag)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:subscribed, ^pid}
  end

  defp forward_events(parent, tag) do
    receive do
      {:mail_changed, _} = event ->
        send(parent, {tag, event})
        forward_events(parent, tag)
    end
  end

  defp connect(workspace, subject) do
    {:ok, account} =
      Access.accept(
        workspace.id,
        %{subject: subject, email: "#{subject}@example.invalid"},
        "token-#{subject}"
      )

    account
  end

  defp set_status(account, fields),
    do:
      Mail.update_account!(account, Map.put(fields, :expected_generation, account.generation),
        actor: @owner
      )

  defp job(account),
    do: %Oban.Job{args: %{"account_id" => account.id, "generation" => account.generation}}

  defp entries(account),
    do:
      CacheEntry
      |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
      |> Ash.read!()
end
