defmodule Lovelace.MailReadTest do
  use Lovelace.DataCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite
  alias Lovelace.Google.Access
  alias Lovelace.Mail
  alias Lovelace.Mail.{ReadRequest, ReadWorker, RequestOwners, ViewData}
  alias Lovelace.Repo
  @owner %{role: :local_owner}

  setup do
    {:ok, _} = Lovelace.TestMail.start()

    previous =
      for key <- [:gmail_provider, :gmail_vault],
          into: %{},
          do: {key, Application.get_env(:lovelace, key)}

    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value,
          do: Application.put_env(:lovelace, key, value),
          else: Application.delete_env(:lovelace, key)
      end)
    end)

    workspace = Lovelace.Workspaces.create_workspace!("Read fixture", actor: @owner)

    {:ok, account} =
      Access.accept(
        workspace.id,
        %{subject: "read-fixture", email: "read@example.invalid"},
        "private-read-token"
      )

    %{workspace: workspace, account: account}
  end

  test "worker exit retains view-owned opaque payload with access and generation checks",
       context do
    id = request(context, :thread, %{thread_id: "same-id"})
    observer = self()

    worker =
      spawn(fn -> send(observer, {:finished, perform_job(ReadWorker, %{operation_id: id})}) end)

    assert_receive {:finished, :ok}, 2_000
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}

    assert %{state: :complete, result: {:ok, %{data: nil, data_ref: ref}}} =
             Mail.read_status!(id, actor: @owner)

    assert %{"messages" => [%{"subject" => "access:private-read-token"}]} = ViewData.get(ref)

    {:ok, _} =
      Access.accept(
        context.workspace.id,
        %{subject: context.account.subject, email: context.account.email},
        "replacement"
      )

    assert ViewData.get(ref) == nil
    assert %{state: :expired} = Mail.read_status!(id, actor: @owner)
  end

  test "view exit makes queued read unavailable without provider access", context do
    observer = self()

    view =
      spawn(fn ->
        send(observer, {:accepted, request(context, :page)})
      end)

    assert_receive {:accepted, id}, 2_000
    monitor = Process.monitor(view)
    assert_receive {:DOWN, ^monitor, :process, ^view, _}
    assert RequestOwners.owner(id) == nil
    assert RequestOwners.result(id) == nil
    assert RequestOwners.stage(id, {:ok, %{error: :unavailable}}) == :expired
    assert RequestOwners.publish(id) == :expired
    assert :ok = perform_job(ReadWorker, %{operation_id: id})
    assert %{state: :expired} = Mail.read_status!(id, actor: @owner)
    assert Lovelace.TestMail.calls() == []
  end

  test "late read after detach cannot publish a private result", context do
    id = request(context, :thread, %{thread_id: "same-id"})
    Lovelace.TestMail.response({:wait_thread, self()})
    observer = self()

    worker =
      spawn(fn -> send(observer, {:finished, perform_job(ReadWorker, %{operation_id: id})}) end)

    assert_receive {:thread_waiting, ^worker}, 2_000
    assert {:ok, true} = Mail.unlink(context.workspace.id, context.account.id, actor: @owner)
    send(worker, :continue)
    assert_receive {:finished, :ok}, 2_000
    assert %{state: :expired} = Mail.read_status!(id, actor: @owner)
    assert RequestOwners.result(id) == nil
  end

  test "rapid search supersedes pending work and doesn't persist private inputs in jobs",
       context do
    secret = "distinctive-private-search-string"
    first = request(context, :page, %{query: secret, page_token: "private-continuation"})
    persisted = Ash.get!(ReadRequest, first, actor: @owner)
    assert persisted.input["query"] == secret
    assert persisted.input["page_token"] == "private-continuation"
    refute inspect(persisted) =~ secret
    refute inspect(persisted) =~ "private-continuation"

    ids =
      for n <- 1..150 do
        request(context, :page, %{query: "synthetic-search-#{n}"})
      end

    current = List.last(ids)
    assert Ash.count!(ReadRequest, actor: @owner) == 1
    assert %{state: :expired} = Mail.read_status!(first, actor: @owner)
    assert [%{args: %{"operation_id" => ^current}}] = all_enqueued(worker: ReadWorker)
    refute inspect(all_enqueued()) =~ secret
    assert :ok = perform_job(ReadWorker, %{operation_id: current})
    assert %{state: :complete} = Mail.read_status!(current, actor: @owner)
    assert Ash.get!(ReadRequest, current, actor: @owner).input == %{}
  end

  test "missed completion signal recovers through authorized operation status", context do
    id = request(context, :page)
    assert :ok = perform_job(ReadWorker, %{operation_id: id})
    assert_receive {:mail_operation, ^id}

    assert %{state: :complete, result: {:ok, %{data_ref: ref}}} =
             Mail.read_status!(id, actor: @owner)

    assert %{"threads" => [_]} = ViewData.get(ref)
    other = Lovelace.Workspaces.create_workspace!("Not attached", actor: @owner)

    assert {:error, _} =
             Mail.request_read(
               %{
                 owner: self(),
                 kind: :page,
                 workspace_id: other.id,
                 account_id: context.account.id
               },
               actor: @owner
             )

    assert {:error, _} = Mail.read_status(id)
  end

  test "global credential checks admit an omitted workspace and retain the generation fence",
       %{account: account, workspace: workspace} do
    assert {:ok, true} = Mail.unlink(workspace.id, account.id, actor: @owner)
    before = Mail.get_account!(account.id, actor: @owner)

    args = %{
      owner: self(),
      kind: :credentials,
      account_id: account.id,
      generation: account.generation
    }

    assert {:error, _} =
             Mail.request_read(Map.put(args, :generation, Ash.UUID.generate()), actor: @owner)

    assert all_enqueued(worker: ReadWorker) == []

    assert {:ok, %{operation_id: id, state: :pending}} =
             Mail.request_read(args, actor: @owner)

    assert [%{args: %{"operation_id" => ^id}}] = all_enqueued(worker: ReadWorker)
    assert :ok = perform_job(ReadWorker, %{operation_id: id})

    assert %{state: :complete, result: {:ok, %{status: :accessible}}} =
             Mail.read_status!(id, actor: @owner)

    assert Mail.get_account!(account.id, actor: @owner) == before
    assert Mail.workspace_accounts!(workspace.id, actor: @owner) == []
    assert Lovelace.TestMail.calls() == []
  end

  test "global thread reads retain opaque view content only for the accepted generation",
       %{account: account, workspace: workspace} = context do
    assert {:ok, true} = Mail.unlink(workspace.id, account.id, actor: @owner)
    id = request(context, :thread, %{workspace_id: nil, thread_id: "same-id", force: true})
    assert :ok = perform_job(ReadWorker, %{operation_id: id})

    assert %{state: :complete, result: {:ok, %{data: nil, data_ref: ref}}} =
             status = Mail.read_status!(id, actor: @owner)

    assert %{"id" => "same-id", "messages" => [%{"subject" => "access:private-read-token"}]} =
             ViewData.get(ref)

    refute inspect(status) =~ "private-read-token"
    assert Ash.get!(ReadRequest, id, actor: @owner).input == %{}

    assert {:ok, replacement} =
             Access.accept(
               workspace.id,
               %{subject: account.subject, email: account.email},
               "replacement-global-thread-token"
             )

    refute replacement.generation == account.generation
    assert ViewData.get(ref) == nil
    assert %{state: :expired} = Mail.read_status!(id, actor: @owner)
    assert :ok = perform_job(ReadWorker, %{operation_id: id})
    assert ViewData.get(ref) == nil
  end

  test "expired queued reads neither reach the provider nor retain sensitive input", context do
    secret = "distinctive-expired-read-query"
    id = request(context, :page, %{query: secret, page_token: "private-expired-page"})

    Repo.query!(
      "UPDATE mail_read_requests SET expires_at = '2000-01-01 00:00:00.000000' WHERE id = ?",
      [id]
    )

    assert :ok = perform_job(ReadWorker, %{operation_id: id})
    assert :ok = perform_job(ReadWorker, %{operation_id: id})
    assert %{state: :expired} = Mail.read_status!(id, actor: @owner)
    assert %{state: :expired, input: %{}} = Ash.get!(ReadRequest, id, actor: @owner)
    assert RequestOwners.result(id) == nil
    refute_receive {:mail_operation, ^id}
    assert Lovelace.TestMail.calls() == []
    refute inspect(all_enqueued(worker: ReadWorker)) =~ secret

    current = request(context, :page)
    assert Ash.get(ReadRequest, id, actor: @owner, not_found_error?: false) == {:ok, nil}
    assert :ok = perform_job(ReadWorker, %{operation_id: current})
    assert %{state: :complete} = Mail.read_status!(current, actor: @owner)
  end

  test "a thread that expires while the provider is running cannot publish its late content",
       context do
    id = request(context, :thread, %{thread_id: "private-expiring-thread", force: true})
    Lovelace.TestMail.response({:wait_thread, self()})
    observer = self()

    worker =
      spawn(fn ->
        send(observer, {:expired_read_finished, perform_job(ReadWorker, %{operation_id: id})})
      end)

    assert_receive {:thread_waiting, ^worker}, 2_000

    Repo.query!(
      "UPDATE mail_read_requests SET expires_at = '2000-01-01 00:00:00.000000' WHERE id = ?",
      [id]
    )

    send(worker, :continue)
    assert_receive {:expired_read_finished, :ok}, 2_000
    assert %{state: :expired} = Mail.read_status!(id, actor: @owner)
    assert RequestOwners.result(id) == nil
    refute_receive {:mail_operation, ^id}

    assert %{state: :expired, input: %{}} = Ash.get!(ReadRequest, id, actor: @owner)
  end

  test "the global live-view limit refuses excess work without losing accepted private results",
       context do
    observer = self()

    accepted =
      for n <- 1..128 do
        view =
          spawn(fn ->
            Process.monitor(observer)
            id = request(context, :page, %{workspace_id: nil, query: "capacity-search-#{n}"})
            send(observer, {:view_read_accepted, self(), id})
            observe_view_read(observer, id)
          end)

        assert_receive {:view_read_accepted, ^view, id}, 2_000
        {view, id}
      end

    assert {:error, _} =
             Mail.request_read(
               %{owner: self(), kind: :page, account_id: context.account.id},
               actor: @owner
             )

    assert Ash.count!(ReadRequest, actor: @owner) == 128
    assert length(all_enqueued(worker: ReadWorker)) == 128
    assert Lovelace.TestMail.calls() == []

    for {view, id} <- accepted do
      assert RequestOwners.owner(id) == view
      assert :ok = perform_job(ReadWorker, %{operation_id: id})
      assert RequestOwners.result(id) == nil
      assert %{state: :expired} = Mail.read_status!(id, actor: @owner)
      send(view, :observe)

      assert_receive {:view_read_observed, ^view, ^id,
                      %{state: :complete, result: {:ok, %{data: nil, data_ref: ref}}},
                      %{"threads" => [%{"subject" => "access:private-read-token"}]}},
                     2_000

      assert is_reference(ref)
    end

    for {view, _id} <- accepted do
      monitor = Process.monitor(view)
      send(view, :close)
      assert_receive {:DOWN, ^monitor, :process, ^view, :normal}, 2_000
    end
  end

  test "unknown and wrong-owner cancellation preserve both views' accepted work", context do
    id = request(context, :page)
    job_id = Ash.get!(ReadRequest, id, actor: @owner).job_id
    assert {:ok, true} = Mail.cancel_read(Ash.UUID.generate(), actor: @owner)
    observer = self()

    view =
      spawn(fn ->
        Process.monitor(observer)
        own_id = request(context, :page, %{query: "other-view-search"})
        cancelled = Mail.cancel_read(id, actor: @owner)
        send(observer, {:other_view_cancelled, self(), own_id, cancelled})
        observe_view_read(observer, own_id)
      end)

    assert_receive {:other_view_cancelled, ^view, own_id, {:ok, true}}, 2_000
    assert RequestOwners.owner(id) == self()
    assert RequestOwners.owner(own_id) == view
    assert Repo.get!(Oban.Job, job_id).state == "available"
    assert %{state: :pending} = Mail.read_status!(id, actor: @owner)
    assert :ok = perform_job(ReadWorker, %{operation_id: id})

    assert %{state: :complete, result: {:ok, %{data_ref: ref}}} =
             Mail.read_status!(id, actor: @owner)

    assert %{"threads" => [_]} = ViewData.get(ref)

    assert :ok = perform_job(ReadWorker, %{operation_id: own_id})
    send(view, :observe)

    assert_receive {:view_read_observed, ^view, ^own_id, %{state: :complete},
                    %{"threads" => [_]}},
                   2_000

    monitor = Process.monitor(view)
    send(view, :close)
    assert_receive {:DOWN, ^monitor, :process, ^view, :normal}, 2_000
  end

  test "observation between SQL completion and notification never expires an available result",
       context do
    id = request(context, :page)
    observer = self()

    worker =
      spawn(fn ->
        receive do
          :perform ->
            send(observer, {:read_finished, perform_job(ReadWorker, %{operation_id: id})})
        end
      end)

    handler = {__MODULE__, make_ref()}

    events =
      for span <- [:action, :update],
          do: [:ash, Ash.Domain.Info.short_name(Mail), span, :stop]

    short_name = Ash.Resource.Info.short_name(ReadRequest)

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        &__MODULE__.pause_read_completion/4,
        {worker, observer, short_name}
      )

    try do
      send(worker, :perform)
      assert_receive {:read_completion_written, ^worker}, 2_000

      assert %{state: :complete, result: {:ok, %{data_ref: ref}}} =
               Mail.read_status!(id, actor: @owner)

      assert %{"threads" => [_]} = ViewData.get(ref)

      send(worker, :resume_read_completion)
      assert_receive {:read_finished, :ok}, 2_000

      assert %{state: :complete, result: {:ok, %{data_ref: ref}}} =
               Mail.read_status!(id, actor: @owner)

      assert %{"threads" => [_]} = ViewData.get(ref)
    after
      send(worker, :resume_read_completion)
      :telemetry.detach(handler)
    end
  end

  test "a failed first admission leaves no orphaned intent or view ownership and can recover",
       context do
    Repo.query!("""
    CREATE TEMP TRIGGER synthetic_first_mail_enqueue_failure
    BEFORE INSERT ON oban_jobs
    BEGIN
      SELECT RAISE(ABORT, 'synthetic first enqueue failure');
    END
    """)

    try do
      assert {:error, _} =
               Mail.request_read(
                 %{
                   owner: self(),
                   kind: :page,
                   workspace_id: context.workspace.id,
                   account_id: context.account.id
                 },
                 actor: @owner
               )

      assert Ash.read!(ReadRequest, actor: @owner) == []
      assert all_enqueued(worker: ReadWorker) == []
      owner = self()
      refute Enum.any?(:sys.get_state(RequestOwners), fn {_, entry} -> entry.owner == owner end)
    after
      Repo.query!("DROP TRIGGER synthetic_first_mail_enqueue_failure")
    end

    id = request(context, :page)
    assert :ok = perform_job(ReadWorker, %{operation_id: id})

    assert %{state: :complete, result: {:ok, %{data_ref: ref}}} =
             Mail.read_status!(id, actor: @owner)

    assert %{"threads" => [_]} = ViewData.get(ref)
  end

  test "enqueue exceptions preserve prior pending work and completed view results", context do
    for complete? <- [false, true] do
      previous = request(context, :page)
      if complete?, do: perform_job(ReadWorker, %{operation_id: previous})
      prior = Mail.read_status!(previous, actor: @owner)
      prior_job = Ash.get!(ReadRequest, previous, actor: @owner).job_id

      Repo.query!("""
      CREATE TEMP TRIGGER synthetic_mail_enqueue_failure
      BEFORE INSERT ON oban_jobs
      BEGIN
        SELECT RAISE(ABORT, 'synthetic mail enqueue failure');
      END
      """)

      try do
        assert {:error, _} =
                 Mail.request_read(
                   %{
                     owner: self(),
                     kind: :page,
                     workspace_id: context.workspace.id,
                     account_id: context.account.id,
                     query: "synthetic rejected search"
                   },
                   actor: @owner
                 )
      after
        Repo.query!("DROP TRIGGER IF EXISTS synthetic_mail_enqueue_failure")
      end

      assert Mail.read_status!(previous, actor: @owner) == prior
      assert RequestOwners.owner(previous) == self()
      owner = self()
      owned = RequestOwners |> :sys.get_state() |> Enum.filter(fn {_, e} -> e.owner == owner end)
      assert [{^previous, _}] = owned
      assert [request] = Ash.read!(ReadRequest, actor: @owner)
      assert request.id == previous
      assert Repo.get!(Oban.Job, prior_job).state != "cancelled"
      assert [%{args: %{"operation_id" => ^previous}}] = all_enqueued(worker: ReadWorker)

      unless complete? do
        assert :ok = perform_job(ReadWorker, %{operation_id: previous})

        assert %{state: :complete, result: {:ok, %{data_ref: ref}}} =
                 Mail.read_status!(previous, actor: @owner)

        assert %{"threads" => [_]} = ViewData.get(ref)
      end
    end
  end

  test "a failed cancellation does not discard ownership or cancel queued work", context do
    id = request(context, :page)
    job_id = Ash.get!(ReadRequest, id, actor: @owner).job_id

    Repo.query!("""
    CREATE TEMP TRIGGER synthetic_mail_cancel_failure
    BEFORE DELETE ON mail_read_requests
    BEGIN
      SELECT RAISE(ABORT, 'synthetic mail cancellation failure');
    END
    """)

    try do
      refute match?({:ok, true}, Mail.cancel_read(id, actor: @owner))
    after
      Repo.query!("DROP TRIGGER IF EXISTS synthetic_mail_cancel_failure")
    end

    assert RequestOwners.owner(id) == self()
    assert %{state: :pending} = Mail.read_status!(id, actor: @owner)
    assert Repo.get!(Oban.Job, job_id).state == "available"
    assert :ok = perform_job(ReadWorker, %{operation_id: id})
    assert %{state: :complete} = Mail.read_status!(id, actor: @owner)
  end

  test "another view cannot commit or roll back a pending replacement or inspect private results",
       context do
    previous = request(context, :page)
    assert :ok = perform_job(ReadWorker, %{operation_id: previous})
    prior_result = RequestOwners.result(previous)
    replacement = Ash.UUID.generate()
    assert {:ok, ^previous} = RequestOwners.register(replacement, self())
    private_result = {:ok, %{private: "distinctive-private-staged-mail-result"}}
    assert :ok = RequestOwners.stage(replacement, private_result)

    observer = self()

    {view, monitor} =
      spawn_monitor(fn ->
        send(observer, {
          :foreign_admission,
          RequestOwners.commit(replacement),
          RequestOwners.rollback(replacement),
          RequestOwners.result(replacement)
        })
      end)

    assert_receive {:foreign_admission, :expired, :expired, nil}
    assert_receive {:DOWN, ^monitor, :process, ^view, :normal}
    assert RequestOwners.owner(replacement) == self()
    assert RequestOwners.result(replacement) == private_result

    refute inspect(:sys.get_status(RequestOwners), limit: :infinity) =~
             "distinctive-private-staged-mail-result"

    assert RequestOwners.result(replacement) == private_result

    assert :ok = RequestOwners.rollback(replacement)
    assert RequestOwners.owner(replacement) == nil
    assert RequestOwners.owner(previous) == self()
    assert RequestOwners.result(previous) == prior_result
    assert %{state: :complete, result: ^prior_result} = Mail.read_status!(previous, actor: @owner)
  end

  @doc false
  def pause_read_completion(_event, _measurements, metadata, {worker, observer, short_name}) do
    if self() == worker and metadata[:action] == :settle and
         metadata[:resource_short_name] == short_name do
      send(observer, {:read_completion_written, worker})

      receive do
        :resume_read_completion -> :ok
      after
        5_000 -> raise "synthetic read completion barrier timed out"
      end
    end
  end

  defp observe_view_read(observer, id) do
    receive do
      :observe ->
        status = Mail.read_status!(id, actor: @owner)
        {:ok, %{data_ref: ref}} = status.result
        send(observer, {:view_read_observed, self(), id, status, ViewData.get(ref)})
        observe_view_read(observer, id)

      :close ->
        :ok

      {:DOWN, _, :process, ^observer, _} ->
        :ok
    end
  end

  defp request(context, kind, options \\ %{}) do
    %{operation_id: id} =
      Mail.request_read!(
        Map.merge(
          %{
            owner: self(),
            kind: kind,
            workspace_id: context.workspace.id,
            account_id: context.account.id
          },
          options
        ),
        actor: @owner
      )

    id
  end
end
