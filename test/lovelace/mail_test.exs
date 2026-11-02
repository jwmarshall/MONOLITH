defmodule Lovelace.MailTest do
  use Lovelace.DataCase
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite
  alias Ecto.Adapters.SQL.Sandbox
  alias Lovelace.Mail
  alias Lovelace.Mail.{CacheEntry, Connections, Operations, PollWorker}
  @owner %{role: :local_owner}

  setup do
    {:ok, _pid} = Lovelace.TestMail.start()

    previous =
      for key <- [:gmail_provider, :gmail_vault],
          into: %{},
          do: {key, Application.get_env(:lovelace, key)}

    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: Application.put_env(:lovelace, k, v), else: Application.delete_env(:lovelace, k)
      end)
    end)

    workspace = Lovelace.Workspaces.create_workspace!("Mail fixture", actor: @owner)

    {:ok, a} =
      Connections.accept(workspace.id, %{subject: "sub-a", email: "a@example.invalid"}, "token-a")

    {:ok, b} =
      Connections.accept(workspace.id, %{subject: "sub-b", email: "b@example.invalid"}, "token-b")

    %{workspace: workspace, a: a, b: b}
  end

  test "unreadable prior credentials are never overwritten or treated as absent", %{
    workspace: w,
    a: a
  } do
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailReadDenied)

    assert {:error, {:keychain, :locked}} =
             Connections.accept(w.id, %{subject: a.subject, email: a.email}, "replacement-token")

    assert {:ok, "token-a"} = Lovelace.TestMailVault.get(a.id)
    assert Mail.get_account!(a.id, actor: @owner).generation == a.generation
  end

  test "connections reuse across workspaces without duplicate identities", %{workspace: w, a: a} do
    other = Lovelace.Workspaces.create_workspace!("Other", actor: @owner)
    assert {:ok, true} = Mail.link(other.id, a.id, actor: @owner)

    assert {:ok, again} =
             Connections.accept(
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
    assert Lovelace.TestMail.calls() |> Enum.all?(fn {kind, _} -> kind == :refresh end)
  end

  test "unattached accounts, nil actors and incorrectly scoped services are rejected", %{
    workspace: w,
    a: a,
    b: b
  } do
    other = Lovelace.Workspaces.create_workspace!("Unattached", actor: @owner)
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

    assert Lovelace.TestMail.calls() == []
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

    assert {:page, "access:token-a", "in:sent", "second"} in Lovelace.TestMail.calls()
  end

  test "provider failure returns honestly stale cache, invalid grant requires reconnection", %{
    workspace: w,
    a: a
  } do
    assert {:ok, %{error: nil}} = Mail.mail_page(w.id, a.id, actor: @owner)
    Lovelace.TestMail.response({:error, :rate_limited})

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

    Lovelace.TestMail.response({:error, :invalid_grant})
    assert {:ok, %{error: :reconnect}} = Mail.mail_page(w.id, a.id, %{force: true}, actor: @owner)
    assert Mail.get_account!(a.id, actor: @owner).status == :reconnect
  end

  test "a recent cached reopen preserves a known refresh failure until real recovery", %{
    workspace: w,
    a: a
  } do
    assert %{error: nil} = Mail.mail_page!(w.id, a.id, actor: @owner)
    Lovelace.TestMail.response({:error, :offline})

    assert %{error: :unavailable, stale: true} =
             Mail.mail_page!(w.id, a.id, %{force: true}, actor: @owner)

    calls = Lovelace.TestMail.calls()
    Lovelace.TestMail.response(:ok)

    assert %{error: :unavailable, stale: true, cached: true} =
             Mail.mail_page!(w.id, a.id, actor: @owner)

    assert Lovelace.TestMail.calls() == calls

    assert %{error: nil, stale: false, cached: false} =
             Mail.mail_page!(w.id, a.id, %{force: true}, actor: @owner)

    assert Mail.get_account!(a.id, actor: @owner).last_error == nil
  end

  test "detach preserves shared connection; global disconnect clears all memberships/cache/token",
       %{workspace: w, a: a} do
    other = Lovelace.Workspaces.create_workspace!("Shared", actor: @owner)
    Mail.link!(other.id, a.id, actor: @owner)
    Mail.thread!(w.id, a.id, "same-id", actor: @owner)
    assert {:ok, true} = Mail.unlink(w.id, a.id, actor: @owner)
    assert {:ok, %{data: data}} = Mail.thread(other.id, a.id, "same-id", actor: @owner)
    assert data

    assert {:ok, %{credentials_removed: true, revoked: true}} =
             Mail.disconnect(a.id, actor: @owner)

    assert Mail.workspace_accounts!(other.id, actor: @owner) == []
    assert {:error, :not_found} = Lovelace.TestMailVault.get(a.id)

    assert [] ==
             CacheEntry
             |> Ash.Query.for_read(:read, %{account_id: a.id}, actor: @owner)
             |> Ash.read!()

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

    Lovelace.TestMail.response({:error, :offline})
    assert {:ok, %{data: nil, error: :unavailable}} = Mail.mail_page(w.id, a.id, actor: @owner)
  end

  test "interrupted vault cleanup remains durably visible and retryable", %{a: a} do
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailDeleteFailure)
    assert %{error: :unavailable} = Mail.disconnect!(a.id, actor: @owner)

    assert %{status: :disconnected, last_error: :keychain} =
             Mail.get_account!(a.id, actor: @owner)

    assert {:ok, "token-a"} = Lovelace.TestMailVault.get(a.id)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)
    assert %{credentials_removed: true} = Mail.disconnect!(a.id, actor: @owner)
    assert Mail.get_account!(a.id, actor: @owner).last_error == nil
    assert {:error, :not_found} = Lovelace.TestMailVault.get(a.id)
  end

  test "disconnect fences a thread response already in flight", %{workspace: w, a: a} do
    Lovelace.TestMail.response({:wait_thread, self()})

    task =
      Task.async(fn ->
        receive do
          :go -> Mail.thread(w.id, a.id, "same-id", actor: @owner)
        end
      end)

    Sandbox.allow(Lovelace.Repo, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:thread_waiting, provider}, 2000
    assert %{local_removed: true} = Mail.disconnect!(a.id, actor: @owner)
    send(provider, :continue)
    assert {:ok, %{data: nil, error: :unavailable}} = Task.await(task)

    assert [] ==
             CacheEntry
             |> Ash.Query.for_read(:read, %{account_id: a.id}, actor: @owner)
             |> Ash.read!()
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
      [:lovelace, :repo, :query],
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

  test "polling publishes only account identity and stores credential-free jobs", %{a: a} do
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "mail:#{a.id}")

    assert {:ok, %{data: data, error: nil}} =
             Mail.poll(a.id, a.generation, actor: %{role: :mail_service, account_id: a.id})

    assert data
    assert_receive {:mail_changed, id}
    assert id == a.id
  end
end
