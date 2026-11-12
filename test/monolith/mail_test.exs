defmodule Monolith.MailTest do
  use Monolith.DataCase
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite
  alias Ecto.Adapters.SQL.Sandbox
  alias Monolith.Google.Access
  alias Monolith.Mail
  alias Monolith.Mail.{CacheEntry, DisconnectWorker, Operations, PollWorker}
  require Ash.Query

  @owner %{role: :local_owner}

  setup do
    {:ok, _pid} = Monolith.TestMail.start()

    previous =
      for key <- [:gmail_provider, :gmail_vault],
          into: %{},
          do: {key, Application.get_env(:monolith, key)}

    Application.put_env(:monolith, :gmail_provider, Monolith.TestGoogle)
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailVault)

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: Application.put_env(:monolith, k, v), else: Application.delete_env(:monolith, k)
      end)
    end)

    workspace = Monolith.Workspaces.create_workspace!("Mail fixture", actor: @owner)

    {:ok, a} =
      Access.accept(workspace.id, %{subject: "sub-a", email: "a@example.invalid"}, "token-a")

    {:ok, b} =
      Access.accept(workspace.id, %{subject: "sub-b", email: "b@example.invalid"}, "token-b")

    %{workspace: workspace, a: a, b: b}
  end

  test "Calendar consent reuses the identity and Gmail reconnect requires fresh Calendar consent",
       %{
         workspace: w,
         a: a
       } do
    refute a.calendar_enabled

    assert {:ok, enabled} =
             Access.accept(
               w.id,
               %{subject: a.subject, email: a.email},
               "calendar-refresh",
               :calendar,
               a.generation
             )

    assert enabled.id == a.id
    assert enabled.calendar_enabled
    assert enabled.status == :ready
    assert {:ok, "calendar-refresh"} = Monolith.TestMailVault.get(a.id)

    assert {:ok, reconnected} =
             Access.accept(w.id, %{subject: a.subject, email: a.email}, "gmail-refresh")

    refute reconnected.calendar_enabled
    assert reconnected.id == a.id
  end

  test "late Calendar consent cannot resurrect a disconnected account or overwrite its vault", %{
    workspace: w,
    a: a
  } do
    assert {:ok,
            %{
              operation_id: operation_id,
              state: :pending,
              local_removed: true,
              credentials: :pending,
              credentials_removed: false,
              remote: :pending,
              revoked: false
            }} = Mail.disconnect(a.id, actor: @owner)

    assert {:error, :reconnect} =
             Access.accept(
               w.id,
               %{subject: a.subject, email: a.email},
               "late-calendar-refresh",
               :calendar,
               a.generation
             )

    assert {:ok, "token-a"} = Monolith.TestMailVault.get(a.id)
    assert :ok = perform_job(DisconnectWorker, %{"operation_id" => operation_id})

    assert {:ok,
            %{
              operation_id: ^operation_id,
              state: :complete,
              local_removed: true,
              credentials: :removed,
              credentials_removed: true,
              remote: :revoked,
              revoked: true
            }} = Mail.disconnect_status(a.id, actor: @owner)

    assert {:error, :not_found} = Monolith.TestMailVault.get(a.id)
    assert Mail.get_account!(a.id, actor: @owner).status == :disconnected
    assert Mail.workspace_accounts!(w.id, actor: @owner) |> Enum.all?(&(&1.account_id != a.id))
  end

  test "unreadable prior credentials are never overwritten or treated as absent", %{
    workspace: w,
    a: a
  } do
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailReadDenied)

    assert {:error, {:keychain, :locked}} =
             Access.accept(w.id, %{subject: a.subject, email: a.email}, "replacement-token")

    assert {:ok, "token-a"} = Monolith.TestMailVault.get(a.id)
    assert Mail.get_account!(a.id, actor: @owner).generation == a.generation
  end

  test "connections reuse across workspaces without duplicate identities", %{workspace: w, a: a} do
    other = Monolith.Workspaces.create_workspace!("Other", actor: @owner)
    assert {:ok, true} = Mail.link(other.id, a.id, actor: @owner)

    assert {:ok, again} =
             Access.accept(
               w.id,
               %{subject: "sub-a", email: "renamed@example.invalid"},
               "token-new"
             )

    assert again.id == a.id
    assert length(Mail.list_accounts!(actor: @owner)) == 2
    assert [%{account_id: id}] = Mail.workspace_accounts!(other.id, actor: @owner)
    assert id == a.id

    assert_enqueued(
      worker: PollWorker,
      args: %{account_id: again.id, generation: again.generation}
    )
  end

  test "workspace connection overview is owner-only metadata", %{workspace: w, a: a, b: b} do
    other = Monolith.Workspaces.create_workspace!("Another area", actor: @owner)
    assert {:ok, true} = Mail.link(other.id, a.id, actor: @owner)

    rows = Mail.list_workspace_accounts!(actor: @owner)

    assert MapSet.new(rows, &{&1.workspace_id, &1.account_id}) ==
             MapSet.new([{w.id, a.id}, {w.id, b.id}, {other.id, a.id}])

    assert {:error, _} = Mail.list_workspace_accounts()

    assert {:error, _} =
             Mail.list_workspace_accounts(actor: %{role: :mail_service, account_id: a.id})

    assert Monolith.TestMail.calls() == []
  end

  test "same provider IDs are namespaced and reads never mutate Gmail", %{
    workspace: w,
    a: a,
    b: b
  } do
    assert {:ok, first} = Mail.thread(w.id, a.id, "same-id", actor: @owner)
    assert {:ok, second} = Mail.thread(w.id, b.id, "same-id", actor: @owner)
    assert first.error == nil
    assert second.error == nil
    assert hd(first.data["messages"])["subject"] == "access:token-a"
    assert hd(second.data["messages"])["subject"] == "access:token-b"
    assert Monolith.TestMail.calls() |> Enum.all?(fn {kind, _} -> kind == :refresh end)
  end

  test "unattached accounts, nil actors and incorrectly scoped services are rejected", %{
    workspace: w,
    a: a,
    b: b
  } do
    other = Monolith.Workspaces.create_workspace!("Unattached", actor: @owner)
    assert {:ok, %{data: nil}} = Mail.mail_page(other.id, a.id, actor: @owner)
    assert {:error, _} = Mail.mail_page(w.id, a.id)

    assert {:ok, %{error: :unavailable}} =
             Mail.poll(a.id, a.generation, actor: %{role: :mail_service, account_id: b.id})

    assert {:error, _} =
             CacheEntry
             |> Ash.Query.for_read(:read, %{account_id: a.id},
               actor: %{role: :mail_service, account_id: b.id}
             )
             |> Ash.read()

    assert Monolith.TestMail.calls() == []
  end

  test "an A-scoped service cannot upsert B through a conflicting Google subject", %{a: a, b: b} do
    assert {:error, _} =
             Mail.save_connection(
               %{id: a.id, subject: b.subject, email: a.email, generation: Ash.UUID.generate()},
               actor: %{role: :mail_service, account_id: a.id}
             )

    current_a = Mail.get_account!(a.id, actor: @owner)
    current_b = Mail.get_account!(b.id, actor: @owner)

    assert {current_a.subject, current_a.email, current_a.generation} ==
             {a.subject, a.email, a.generation}

    assert {current_b.subject, current_b.email, current_b.generation} ==
             {b.subject, b.email, b.generation}
  end

  test "pagination and whole-account search retain account and query", %{workspace: w, a: a} do
    assert {:ok, %{data: %{"next_page_token" => "second"}}} =
             Mail.mail_page(w.id, a.id, %{query: "in:sent", page_token: nil}, actor: @owner)

    assert {:ok, %{data: %{"next_page_token" => nil}}} =
             Mail.mail_page(w.id, a.id, %{query: "in:sent", page_token: "second"}, actor: @owner)

    assert {:page, "access:token-a", "in:sent", "second"} in Monolith.TestMail.calls()
  end

  test "provider failure returns honestly stale cache, invalid grant requires reconnection", %{
    workspace: w,
    a: a
  } do
    assert {:ok, %{error: nil}} = Mail.mail_page(w.id, a.id, actor: @owner)
    Monolith.TestMail.response({:error, :rate_limited})

    assert {:ok, %{stale: true, error: :rate_limited, data: data}} =
             Mail.mail_page(w.id, a.id, %{force: true}, actor: @owner)

    assert data
    current = Mail.get_account!(a.id, actor: @owner)

    Mail.update_account!(
      current,
      %{
        expected_generation: current.generation,
        next_poll_at: DateTime.add(DateTime.utc_now(), -1)
      },
      actor: @owner
    )

    Monolith.TestMail.response({:error, :invalid_grant})
    assert {:ok, %{error: :reconnect}} = Mail.mail_page(w.id, a.id, %{force: true}, actor: @owner)
    assert Mail.get_account!(a.id, actor: @owner).status == :reconnect
  end

  test "legacy cached threads retry for attachment metadata and preserve the body offline", %{
    a: a
  } do
    payload = %{
      "id" => "same-id",
      "messages" => [%{"id" => "message", "subject" => "cached", "text" => "body"}]
    }

    CacheEntry
    |> Ash.Changeset.for_create(
      :store,
      %{
        account_id: a.id,
        key: "thread:same-id",
        generation: a.generation,
        payload: payload,
        bytes: byte_size(Jason.encode!(payload)),
        fetched_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 60_000)
      },
      actor: @owner
    )
    |> Ash.create!()

    Monolith.TestMail.response({:error, :offline})

    assert %{error: :unavailable, stale: true, data: ^payload} =
             Mail.account_thread!(a.id, "same-id", actor: @owner)

    Monolith.TestMail.response(:ok)

    assert %{error: nil, cached: false, data: %{"messages" => [message]}} =
             Mail.account_thread!(a.id, "same-id", actor: @owner)

    assert [%{"attachment_id" => "part-a"}] = message["attachments"]
  end

  test "a recent cached reopen preserves a known refresh failure until real recovery", %{
    workspace: w,
    a: a
  } do
    assert %{error: nil} = Mail.mail_page!(w.id, a.id, actor: @owner)
    Monolith.TestMail.response({:error, :offline})

    assert %{error: :unavailable, stale: true} =
             Mail.mail_page!(w.id, a.id, %{force: true}, actor: @owner)

    calls = Monolith.TestMail.calls()
    Monolith.TestMail.response(:ok)

    assert %{error: :unavailable, stale: true, cached: true} =
             Mail.mail_page!(w.id, a.id, actor: @owner)

    assert Monolith.TestMail.calls() == calls

    assert %{error: nil, stale: false, cached: false} =
             Mail.mail_page!(w.id, a.id, %{force: true}, actor: @owner)

    assert Mail.get_account!(a.id, actor: @owner).last_error == nil
  end

  test "detach preserves shared connection; global disconnect clears all memberships/cache/token",
       %{workspace: w, a: a} do
    other = Monolith.Workspaces.create_workspace!("Shared", actor: @owner)
    Mail.link!(other.id, a.id, actor: @owner)
    Mail.thread!(w.id, a.id, "same-id", actor: @owner)
    assert {:ok, true} = Mail.unlink(w.id, a.id, actor: @owner)
    assert {:ok, %{data: data}} = Mail.thread(other.id, a.id, "same-id", actor: @owner)
    assert data

    assert {:ok,
            %{
              operation_id: operation_id,
              state: :pending,
              local_removed: true,
              credentials: :pending,
              credentials_removed: false,
              remote: :pending,
              revoked: false
            }} = Mail.disconnect(a.id, actor: @owner)

    assert Mail.workspace_accounts!(other.id, actor: @owner) == []
    assert {:ok, "token-a"} = Monolith.TestMailVault.get(a.id)
    refute {:revoke, "token-a"} in Monolith.TestMail.calls()

    assert [] ==
             CacheEntry
             |> Ash.Query.for_read(:read, %{account_id: a.id}, actor: @owner)
             |> Ash.read!()

    assert :ok = perform_job(DisconnectWorker, %{"operation_id" => operation_id})

    assert {:ok,
            %{
              operation_id: ^operation_id,
              state: :complete,
              local_removed: true,
              credentials: :removed,
              credentials_removed: true,
              remote: :revoked,
              revoked: true
            }} = Mail.disconnect_status(a.id, actor: @owner)

    assert {:error, :not_found} = Monolith.TestMailVault.get(a.id)

    assert {:ok, %{skipped: true}} =
             Mail.poll(a.id, a.generation, actor: %{role: :mail_service, account_id: a.id})
  end

  test "expired cache is pruned and not served offline", %{workspace: w, a: a} do
    Mail.mail_page!(w.id, a.id, actor: @owner)

    entry =
      CacheEntry
      |> Ash.Query.for_read(:read, %{account_id: a.id}, actor: @owner)
      |> Ash.read_one!()

    CacheEntry
    |> Ash.Changeset.for_create(
      :store,
      %{
        account_id: a.id,
        key: entry.key,
        generation: a.generation,
        payload: entry.payload,
        bytes: entry.bytes,
        fetched_at: DateTime.add(DateTime.utc_now(), -700_000),
        expires_at: DateTime.add(DateTime.utc_now(), -1)
      },
      actor: @owner
    )
    |> Ash.create!()

    Monolith.TestMail.response({:error, :offline})
    assert {:ok, %{data: nil, error: :unavailable}} = Mail.mail_page(w.id, a.id, actor: @owner)
  end

  test "interrupted vault cleanup remains durably visible and retryable", %{a: a} do
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailDeleteFailure)

    assert {:ok,
            %{
              operation_id: operation_id,
              state: :pending,
              local_removed: true,
              credentials: :pending,
              credentials_removed: false,
              remote: :pending,
              revoked: false
            }} = Mail.disconnect(a.id, actor: @owner)

    assert :ok = perform_job(DisconnectWorker, %{"operation_id" => operation_id})

    assert {:ok,
            %{
              operation_id: ^operation_id,
              state: :complete,
              local_removed: true,
              credentials: :failed,
              credentials_removed: false,
              remote: :revoked,
              revoked: true
            }} = Mail.disconnect_status(a.id, actor: @owner)

    assert Enum.count(Monolith.TestMail.calls(), &match?({:revoke, "token-a"}, &1)) == 1

    assert %{status: :disconnected, last_error: :keychain} =
             Mail.get_account!(a.id, actor: @owner)

    assert {:ok, "token-a"} = Monolith.TestMailVault.get(a.id)
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailVault)

    assert {:ok,
            %{
              operation_id: ^operation_id,
              state: :pending,
              local_removed: true,
              credentials: :failed,
              credentials_removed: false,
              remote: :revoked,
              revoked: true
            }} = Mail.disconnect(a.id, actor: @owner)

    assert :ok = perform_job(DisconnectWorker, %{"operation_id" => operation_id})

    assert {:ok,
            %{
              operation_id: ^operation_id,
              state: :complete,
              local_removed: true,
              credentials: :removed,
              credentials_removed: true,
              remote: :revoked,
              revoked: true
            }} = Mail.disconnect_status(a.id, actor: @owner)

    assert Enum.count(Monolith.TestMail.calls(), &match?({:revoke, "token-a"}, &1)) == 1
    assert Mail.get_account!(a.id, actor: @owner).last_error == nil
    assert {:error, :not_found} = Monolith.TestMailVault.get(a.id)
  end

  test "disconnect fences a thread response already in flight", %{workspace: w, a: a} do
    Monolith.TestMail.response({:wait_thread, self()})

    task =
      Task.async(fn ->
        receive do
          :go -> Mail.thread(w.id, a.id, "same-id", actor: @owner)
        end
      end)

    Sandbox.allow(Monolith.Repo, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:thread_waiting, provider}, 2000

    assert {:ok,
            %{
              operation_id: operation_id,
              state: :pending,
              local_removed: true,
              credentials: :pending,
              credentials_removed: false,
              remote: :pending,
              revoked: false
            }} = Mail.disconnect(a.id, actor: @owner)

    send(provider, :continue)
    assert {:ok, %{data: nil, error: :unavailable}} = Task.await(task)

    assert [] ==
             CacheEntry
             |> Ash.Query.for_read(:read, %{account_id: a.id}, actor: @owner)
             |> Ash.read!()

    assert :ok = perform_job(DisconnectWorker, %{"operation_id" => operation_id})

    assert {:ok,
            %{
              operation_id: ^operation_id,
              state: :complete,
              local_removed: true,
              credentials: :removed,
              credentials_removed: true,
              remote: :revoked,
              revoked: true
            }} = Mail.disconnect_status(a.id, actor: @owner)
  end

  test "stale account status updates cannot undo a new connection generation", %{a: a} do
    current =
      Mail.save_connection!(
        %{id: a.id, subject: a.subject, email: a.email, generation: Ash.UUID.generate()},
        actor: @owner
      )

    assert {:error, _} =
             Mail.update_account(a, %{expected_generation: a.generation, status: :reconnect},
               actor: @owner
             )

    assert Mail.get_account!(a.id, actor: @owner).generation == current.generation
    assert Mail.get_account!(a.id, actor: @owner).status == :ready
  end

  test "retention bounds are per account and evict oldest entries", %{a: a, b: b} do
    for i <- 1..122 do
      CacheEntry
      |> Ash.Changeset.for_create(
        :store,
        %{
          account_id: a.id,
          key: "entry-#{i}",
          generation: a.generation,
          payload: %{"fixture" => i},
          bytes: 4,
          fetched_at: DateTime.add(DateTime.utc_now(), i),
          expires_at: DateTime.add(DateTime.utc_now(), 60)
        },
        actor: @owner
      )
      |> Ash.create!()
    end

    CacheEntry
    |> Ash.Changeset.for_create(
      :store,
      %{
        account_id: b.id,
        key: "other",
        generation: b.generation,
        payload: %{},
        bytes: 2,
        fetched_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 60)
      },
      actor: @owner
    )
    |> Ash.create!()

    Operations.prune(a.id, @owner)

    entries =
      CacheEntry |> Ash.Query.for_read(:read, %{account_id: a.id}, actor: @owner) |> Ash.read!()

    assert length(entries) == 120
    refute Enum.any?(entries, &(&1.key in ["entry-1", "entry-2"]))

    assert [_] =
             CacheEntry
             |> Ash.Query.for_read(:read, %{account_id: b.id}, actor: @owner)
             |> Ash.read!()
  end

  test "mail SQL reads and writes emit no payload-bearing query telemetry or logs", %{
    workspace: w,
    a: a
  } do
    pid = self()
    handler = "mail-sql-privacy-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:monolith, :repo, :query],
      fn _, _, metadata, _ -> send(pid, {:sql_payload, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{data: data} = Mail.thread!(w.id, a.id, "same-id", actor: @owner)
        assert data
        assert %{cached: true} = Mail.thread!(w.id, a.id, "same-id", actor: @owner)
      end)

    refute log =~ "synthetic"
    refute log =~ "token-a"
    refute_receive {:sql_payload, _}
  end

  test "owner account reads work with no memberships without weakening workspace reads", %{
    workspace: w,
    a: a,
    b: b
  } do
    Mail.unlink!(w.id, a.id, actor: @owner)
    Mail.unlink!(w.id, b.id, actor: @owner)
    assert %{error: :unavailable} = Mail.mail_page!(w.id, a.id, actor: @owner)
    assert %{error: :unavailable} = Mail.thread!(w.id, a.id, "same-id", actor: @owner)
    assert Monolith.TestMail.calls() == []

    assert %{error: nil, data: page} = Mail.account_page!(a.id, actor: @owner)
    assert hd(page["threads"])["subject"] == "access:token-a"

    assert %{error: nil, data: search} =
             Mail.account_page!(a.id, %{query: "in:sent", page_token: "second"}, actor: @owner)

    assert search["next_page_token"] == nil
    assert {:page, "access:token-a", "in:sent", "second"} in Monolith.TestMail.calls()
    assert %{error: nil, data: first} = Mail.account_thread!(a.id, "same-id", actor: @owner)
    assert %{error: nil, data: second} = Mail.account_thread!(b.id, "same-id", actor: @owner)
    assert hd(first["messages"])["subject"] == "access:token-a"
    assert hd(second["messages"])["subject"] == "access:token-b"

    assert %{cached: true, data: ^first} =
             Mail.account_thread!(a.id, "same-id", actor: @owner)
  end

  test "attachment bytes require account-scoped thread metadata and stay out of the mail cache",
       %{
         a: a,
         b: b
       } do
    assert %{error: nil} = Mail.account_thread!(a.id, "same-id", actor: @owner)

    assert %{bytes: "synthetic file", filename: "note.txt", size: 14} =
             Mail.attachment!(a.id, "same-id", "message", "part-a", actor: @owner)

    assert {:attachment, "access:token-a", "message", "part-a"} in Monolith.TestMail.calls()

    assert %{error: :unavailable} =
             Mail.attachment!(b.id, "same-id", "message", "part-a", actor: @owner)

    # Both accounts reuse provider thread, message and attachment IDs; B must use B's token.
    assert %{error: nil} = Mail.account_thread!(b.id, "same-id", actor: @owner)

    assert %{bytes: "synthetic file"} =
             Mail.attachment!(b.id, "same-id", "message", "part-a", actor: @owner)

    assert {:attachment, "access:token-b", "message", "part-a"} in Monolith.TestMail.calls()

    assert %{error: :unavailable} =
             Mail.attachment!(a.id, "same-id", "message", "message", actor: @owner)

    cached =
      CacheEntry
      |> Ash.Query.for_read(:read, %{account_id: a.id}, actor: @owner)
      |> Ash.Query.filter(key == "thread:same-id")
      |> Ash.read_one!()

    refute inspect(cached.payload) =~ "synthetic file"
  end

  test "attachment bytes are discarded when the account reconnects during provider fetch", %{
    a: a
  } do
    assert %{error: nil} = Mail.account_thread!(a.id, "same-id", actor: @owner)
    Monolith.TestMail.response({:wait_attachment, self()})

    task =
      Task.async(fn ->
        receive do
          :go -> Mail.attachment(a.id, "same-id", "message", "part-a", actor: @owner)
        end
      end)

    Sandbox.allow(Monolith.Repo, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:attachment_waiting, provider}, 2000

    connected =
      Mail.save_connection!(
        %{id: a.id, subject: a.subject, email: a.email, generation: Ash.UUID.generate()},
        actor: @owner
      )

    send(provider, :continue)
    assert {:ok, %{error: :unavailable, data: nil}} = Task.await(task)
    assert Mail.get_account!(a.id, actor: @owner).generation == connected.generation
  end

  test "direct account reads require the owner, never a service or anonymous actor", %{a: a} do
    for actor <- [nil, %{role: :mail_service, account_id: a.id}] do
      assert {:error, _} = Mail.account_page(a.id, actor: actor)
      assert {:error, _} = Mail.account_thread(a.id, "same-id", actor: actor)
    end

    assert Monolith.TestMail.calls() == []
  end

  test "direct account reads reject reconnect and disconnected identities before provider work",
       %{
         a: a
       } do
    for {status, error} <- [reconnect: :reconnect, disconnected: :unavailable] do
      Mail.update_account!(a, %{expected_generation: a.generation, status: status}, actor: @owner)
      assert %{error: ^error, data: nil} = Mail.account_page!(a.id, actor: @owner)
      assert %{error: ^error, data: nil} = Mail.account_thread!(a.id, "same-id", actor: @owner)
    end

    assert Monolith.TestMail.calls() == []
  end

  test "direct account thread responses are fenced across a new connection generation", %{a: a} do
    Monolith.TestMail.response({:wait_thread, self()})

    task =
      Task.async(fn ->
        receive do
          :go -> Mail.account_thread(a.id, "same-id", actor: @owner)
        end
      end)

    Sandbox.allow(Monolith.Repo, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:thread_waiting, provider}, 2000

    connected =
      Mail.save_connection!(
        %{id: a.id, subject: a.subject, email: a.email, generation: Ash.UUID.generate()},
        actor: @owner
      )

    send(provider, :continue)
    assert {:ok, %{error: :unavailable, data: nil}} = Task.await(task)
    assert Mail.get_account!(a.id, actor: @owner).generation == connected.generation

    assert [] ==
             CacheEntry
             |> Ash.Query.for_read(:read, %{account_id: a.id}, actor: @owner)
             |> Ash.read!()
  end

  test "direct account pages delayed at token refresh are fenced by disconnect", %{a: a} do
    Monolith.TestMail.response({:wait, self()})

    task =
      Task.async(fn ->
        receive do
          :go -> Mail.account_page(a.id, actor: @owner)
        end
      end)

    Sandbox.allow(Monolith.Repo, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:provider_waiting, provider}, 2000

    # Model the committed disconnect fence without waiting for the serial vault
    # boundary currently occupied by this fake token refresh.
    Mail.update_account!(
      a,
      %{
        expected_generation: a.generation,
        status: :disconnected,
        generation: Ash.UUID.generate()
      },
      actor: @owner
    )

    send(provider, :continue)
    assert {:ok, %{error: :unavailable, data: nil}} = Task.await(task)
    refute Enum.any?(Monolith.TestMail.calls(), &match?({:page, _, _, _}, &1))
  end

  test "polling publishes only account identity and stores credential-free jobs", %{a: a} do
    Phoenix.PubSub.subscribe(Monolith.PubSub, "mail:#{a.id}")

    assert {:ok, %{data: data, error: nil}} =
             Mail.poll(a.id, a.generation, actor: %{role: :mail_service, account_id: a.id})

    assert data
    assert_receive {:mail_changed, id}
    assert id == a.id
  end
end
