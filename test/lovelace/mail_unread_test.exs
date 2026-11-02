defmodule Lovelace.MailUnreadTest do
  use Lovelace.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Lovelace.Mail
  alias Lovelace.Mail.{Connections, PollWorker}

  @owner %{role: :local_owner}

  setup do
    {:ok, _} = Lovelace.TestMail.start()
    previous = Keyword.take(Application.get_all_env(:lovelace), [:gmail_provider, :gmail_vault])
    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      for key <- [:gmail_provider, :gmail_vault] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:lovelace, key, value)
          :error -> Application.delete_env(:lovelace, key)
        end
      end
    end)

    workspace = Lovelace.Workspaces.create_workspace!("Unread fixture", actor: @owner)

    accounts =
      for name <- ["a", "b"] do
        {:ok, account} =
          Connections.accept(
            workspace.id,
            %{subject: "unread-#{name}", email: "#{name}@example.invalid"},
            "token-#{name}"
          )

        account
      end

    [a, b] = accounts
    %{workspace: workspace, a: a, b: b}
  end

  test "unknown is not zero; polls observe independent totals without workspace memberships", %{
    workspace: workspace,
    a: a,
    b: b
  } do
    assert {a.inbox_unread_count, a.inbox_unread_at, a.inbox_unread_error} == {nil, nil, nil}
    Mail.unlink!(workspace.id, a.id, actor: @owner)
    Lovelace.TestMail.unread_response({:ok, 0})
    assert %{error: nil} = poll(a)
    observed = current(a)
    assert observed.inbox_unread_count == 0
    assert %DateTime{} = observed.inbox_unread_at
    assert observed.inbox_unread_error == nil
    assert current(b).inbox_unread_count == nil
    assert {:inbox_unread, "access:token-a"} in Lovelace.TestMail.calls()
    refute {:inbox_unread, "access:token-b"} in Lovelace.TestMail.calls()

    Lovelace.TestMail.unread_response({:ok, 123})
    assert %{error: nil} = poll(b)
    assert current(b).inbox_unread_count == 123
    assert current(a).inbox_unread_count == 0
  end

  test "failed and invalid count observations retain count/time despite successful pages", %{
    workspace: workspace,
    a: a
  } do
    poll(a)
    observed = current(a)

    for response <- [{:error, :timeout}, {:error, :invalid_response}, {:ok, -1}, {:ok, "9"}] do
      Lovelace.TestMail.unread_response(response)
      assert %{error: error, stale: true, data: data} = poll(a)
      assert error in [:unavailable, :provider]
      assert data
      failed = current(a)
      assert failed.inbox_unread_count == observed.inbox_unread_count
      assert failed.inbox_unread_at == observed.inbox_unread_at
      assert failed.inbox_unread_error == error
      # A page success is not a successful unread observation.
      assert failed.last_error == nil
      assert %{error: nil} = Mail.mail_page!(workspace.id, a.id, %{force: true}, actor: @owner)
      assert current(a).inbox_unread_error == error
    end

    Lovelace.TestMail.unread_response({:ok, 0})
    assert %{error: nil} = poll(a)
    assert %{inbox_unread_count: 0, inbox_unread_error: nil} = current(a)
    assert DateTime.compare(current(a).inbox_unread_at, observed.inbox_unread_at) == :gt
  end

  test "malformed and raising count providers persist a safe count error, never just outer rescue",
       %{
         a: a
       } do
    poll(a)
    observed = current(a)

    for response <- [
          nil,
          :ok,
          {:ok, nil},
          {:error, %{private: "synthetic-private-count"}},
          {:raise, "synthetic-private-count"},
          {:throw, "synthetic-private-count"},
          {:ok, 99_999_999_999_999_999_999_999}
        ] do
      Lovelace.TestMail.unread_response(response)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{error: error, data: data} = poll(a)
          assert error in [:provider, :unavailable]
          assert data
          assert current(a).inbox_unread_error == error
          assert current(a).inbox_unread_count == observed.inbox_unread_count
          assert current(a).inbox_unread_at == observed.inbox_unread_at
        end)

      refute log =~ "synthetic-private-count"
    end
  end

  test "a page or thread status success already in flight cannot clear a newer count failure", %{
    a: a
  } do
    poll(a)
    observed = current(a)
    Lovelace.TestMail.response({:wait_thread, self()})

    task =
      Task.async(fn ->
        receive do
          :go -> Mail.account_thread!(a.id, "in-flight", actor: @owner)
        end
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:thread_waiting, provider}, 2000
    Lovelace.TestMail.unread_response({:error, :timeout})
    assert %{error: :unavailable} = poll(a)
    send(provider, :continue)
    assert %{error: nil} = Task.await(task)
    assert current(a).last_error == nil
    assert current(a).inbox_unread_error == :unavailable
    assert current(a).inbox_unread_count == observed.inbox_unread_count
    assert current(a).inbox_unread_at == observed.inbox_unread_at
  end

  test "an initial count error stays unknown and count failures use bounded worker retries", %{
    a: a
  } do
    Lovelace.TestMail.unread_response({:error, :timeout})
    assert {:error, :mail_unavailable} = PollWorker.perform(job(a))

    assert %{inbox_unread_count: nil, inbox_unread_at: nil, inbox_unread_error: :unavailable} =
             current(a)
  end

  test "count rate limits retain the previous observation and deny further account work", %{
    workspace: workspace,
    a: a,
    b: b
  } do
    poll(a)
    observed = current(a)
    Lovelace.TestMail.unread_response({:error, :rate_limited})
    assert :ok = PollWorker.perform(job(a))
    limited = current(a)
    assert limited.inbox_unread_count == observed.inbox_unread_count
    assert limited.inbox_unread_at == observed.inbox_unread_at
    assert limited.inbox_unread_error == :rate_limited
    assert limited.last_error == :rate_limited
    calls = Lovelace.TestMail.calls()
    Lovelace.TestMail.unread_response({:ok, 0})
    assert %{error: :rate_limited} = poll(a)
    assert %{error: :rate_limited} = Mail.account_page!(a.id, %{force: true}, actor: @owner)

    assert %{error: :rate_limited} =
             Mail.mail_page!(workspace.id, a.id, %{force: true}, actor: @owner)

    assert Lovelace.TestMail.calls() == calls
    assert current(a).next_poll_at == limited.next_poll_at
    assert %{error: nil} = poll(b)
    assert current(b).inbox_unread_count == 0
    assert current(b).last_error == nil
  end

  test "existing cooldown rejects a count before entering credential coordination", %{a: a} do
    deadline = DateTime.add(DateTime.utc_now(), 300)
    set_status(a, %{last_error: :rate_limited, next_poll_at: deadline})
    calls = Lovelace.TestMail.calls()

    # Holding the token coordination lock makes access_token/1 block if reached.
    # A denied poll must complete without waiting for credentials or provider work.
    Connections.serial(a.id, fn ->
      task = async_poll(a)
      assert {:ok, %{error: :rate_limited}} = Task.yield(task, 2000)
    end)

    assert Lovelace.TestMail.calls() == calls
    assert current(a).inbox_unread_error == :rate_limited
    assert current(a).next_poll_at == deadline
  end

  test "expired admission refusal does not create a new cooldown", %{a: a} do
    expired =
      set_status(a, %{
        last_error: :rate_limited,
        next_poll_at: DateTime.add(DateTime.utc_now(), -1)
      })

    Lovelace.TestMail.response({:error, :cooldown})
    assert %{error: :rate_limited} = poll(a)
    assert current(a).next_poll_at == expired.next_poll_at
    assert current(a).inbox_unread_error == :rate_limited
    refute Enum.any?(Lovelace.TestMail.calls(), &match?({:inbox_unread, _}, &1))
  end

  test "reconnect errors retain observations until a new generation resets them", %{
    workspace: workspace,
    a: a
  } do
    poll(a)
    observed = current(a)
    Lovelace.TestMail.unread_response({:error, :unauthorized})
    assert %{error: :reconnect} = poll(a)
    assert current(a).status == :reconnect
    assert current(a).inbox_unread_error == :reconnect
    assert current(a).inbox_unread_count == observed.inbox_unread_count
    assert current(a).inbox_unread_at == observed.inbox_unread_at
    calls = Lovelace.TestMail.calls()
    assert %{skipped: true} = poll(a)
    assert Lovelace.TestMail.calls() == calls

    {:ok, connected} =
      Connections.accept(workspace.id, %{subject: a.subject, email: a.email}, "new")

    refute connected.generation == a.generation

    assert {connected.inbox_unread_count, connected.inbox_unread_at, connected.inbox_unread_error} ==
             {nil, nil, nil}

    assert %{skipped: true} = poll(a)
    Lovelace.TestMail.unread_response({:ok, 19})
    poll(connected)
    assert current(a).inbox_unread_count == 19
    assert %{local_removed: true} = Mail.disconnect!(a.id, actor: @owner)
    disconnected = current(a)

    assert {disconnected.inbox_unread_count, disconnected.inbox_unread_at,
            disconnected.inbox_unread_error} == {nil, nil, nil}
  end

  test "delayed count success and failure cannot overwrite a reconnected generation", %{
    workspace: workspace,
    a: a
  } do
    for response <- [{:ok, 999}, {:error, :rate_limited}] do
      account = current(a)
      {task, provider} = waiting_poll(account, response)

      {:ok, reconnected} =
        Connections.accept(workspace.id, %{subject: a.subject, email: a.email}, "replacement")

      send(provider, :continue)
      assert %{error: :unavailable} = Task.await(task)
      assert current(a).generation == reconnected.generation
      assert current(a).last_error == nil
      assert current(a).inbox_unread_count == nil
      assert current(a).inbox_unread_at == nil
      assert current(a).inbox_unread_error == nil
    end
  end

  test "disconnect fences a count response already in flight", %{a: a} do
    {task, provider} = waiting_poll(a, {:ok, 999})
    assert %{local_removed: true} = Mail.disconnect!(a.id, actor: @owner)
    send(provider, :continue)
    assert %{error: :unavailable} = Task.await(task)
    assert current(a).status == :disconnected
    assert current(a).inbox_unread_count == nil
    assert current(a).inbox_unread_at == nil
  end

  test "count success and failure in flight cannot clear or extend a newer cooldown", %{a: a} do
    for response <- [{:ok, 8}, {:error, :timeout}, {:error, :rate_limited}] do
      set_status(a, %{last_error: nil, next_poll_at: DateTime.utc_now()})
      {task, provider} = waiting_poll(a, response)
      deadline = DateTime.add(DateTime.utc_now(), 300)
      set_status(a, %{last_error: :rate_limited, next_poll_at: deadline})
      send(provider, :continue)
      assert %{error: :rate_limited} = Task.await(task)
      assert current(a).last_error == :rate_limited
      assert current(a).inbox_unread_error == :rate_limited
      assert current(a).next_poll_at == deadline
    end
  end

  test "token refresh delayed across a new cooldown cannot admit a count request", %{a: a} do
    Lovelace.TestMail.response({:wait, self()})
    task = async_poll(a)
    assert_receive {:provider_waiting, provider}, 2000
    deadline = DateTime.add(DateTime.utc_now(), 300)
    set_status(a, %{last_error: :rate_limited, next_poll_at: deadline})
    send(provider, :continue)
    assert %{error: :rate_limited} = Task.await(task)
    refute Enum.any?(Lovelace.TestMail.calls(), &match?({:inbox_unread, _}, &1))
    assert current(a).next_poll_at == deadline
  end

  test "service actors cannot modify another account's summary", %{a: a, b: b} do
    assert {:error, _} =
             Mail.update_account(
               b,
               %{expected_generation: b.generation, inbox_unread_count: 100},
               actor: %{role: :mail_service, account_id: a.id}
             )

    assert current(b).inbox_unread_count == nil
  end

  defp waiting_poll(account, response) do
    Lovelace.TestMail.unread_response({:wait, self(), response})
    task = async_poll(account)
    assert_receive {:unread_waiting, provider}, 2000
    {task, provider}
  end

  defp async_poll(account) do
    task = Task.async(fn -> receive do: (:go -> poll(account)) end)
    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :go)
    task
  end

  defp poll(account),
    do:
      Mail.poll!(account.id, account.generation,
        actor: %{role: :mail_service, account_id: account.id}
      )

  defp current(account), do: Mail.get_account!(account.id, actor: @owner)

  defp set_status(account, fields),
    do:
      Mail.update_account!(
        current(account),
        Map.put(fields, :expected_generation, account.generation),
        actor: @owner
      )

  defp job(account),
    do: %Oban.Job{args: %{"account_id" => account.id, "generation" => account.generation}}
end
