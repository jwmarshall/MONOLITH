defmodule Monolith.MailDisconnectTest do
  use Monolith.DataCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite
  alias Monolith.Google.Access
  alias Monolith.Mail
  alias Monolith.Mail.{Disconnection, DisconnectWorker}
  @owner %{role: :local_owner}

  defmodule Provider do
    def revoke(token) do
      Monolith.TestMail.record({:revoke, token})

      case Monolith.TestMail.result() do
        {:block_revoke, observer} ->
          send(observer, {:revocation_blocked, self()})

          receive do
            :continue -> :ok
          end

        {:raise, secret} ->
          raise secret

        {:throw, secret} ->
          throw(secret)

        result ->
          result
      end
    end
  end

  setup do
    {:ok, _} = Monolith.TestMail.start()

    previous =
      for key <- [:gmail_provider, :gmail_vault],
          into: %{},
          do: {key, Application.get_env(:monolith, key)}

    Application.put_env(:monolith, :gmail_provider, Provider)
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailVault)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value,
          do: Application.put_env(:monolith, key, value),
          else: Application.delete_env(:monolith, key)
      end)
    end)

    workspace = Monolith.Workspaces.create_workspace!("Synthetic cleanup", actor: @owner)

    {:ok, account} =
      Access.accept(
        workspace.id,
        %{subject: "disconnect-fixture", email: "disconnect@example.invalid"},
        "distinctive-private-cleanup-token"
      )

    %{workspace: workspace, account: account}
  end

  test "accepted cleanup survives requesting view death and remains observable", %{
    account: account
  } do
    observer = self()

    view =
      spawn(fn ->
        send(observer, {:accepted, Mail.disconnect!(account.id, actor: @owner)})

        receive do
          :close -> :ok
        end
      end)

    assert_receive {:accepted, %{operation_id: id, state: :pending}}, 2_000
    assert Mail.get_account!(account.id, actor: @owner).status == :disconnected
    send(view, :close)
    monitor = Process.monitor(view)
    assert_receive {:DOWN, ^monitor, :process, ^view, _}

    Monolith.TestMail.response({:block_revoke, self()})
    worker = spawn(fn -> perform_job(DisconnectWorker, %{operation_id: id}) end)
    assert_receive {:revocation_blocked, ^worker}, 2_000

    assert %{remote: :claimed, credentials_removed: false} =
             Mail.disconnect_status!(account.id, actor: @owner)

    send(worker, :continue)
    worker_monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 2_000

    assert %{operation_id: ^id, state: :complete, remote: :revoked, credentials_removed: true} =
             Mail.disconnect_status!(account.id, actor: @owner)

    assert {:error, :not_found} = Monolith.TestMailVault.get(account.id)
    assert Mail.get_account!(account.id, actor: @owner).last_error == nil
  end

  test "missing credential is unavailable remote access, never verified revocation", %{
    account: account
  } do
    Monolith.TestMailVault.delete(account.id)
    %{operation_id: id} = Mail.disconnect!(account.id, actor: @owner)
    assert :ok = perform_job(DisconnectWorker, %{operation_id: id})

    assert %{local_removed: true, credentials_removed: true, revoked: false, remote: :unavailable} =
             Mail.disconnect_status!(account.id, actor: @owner)

    assert Monolith.TestMail.calls() == []
  end

  test "rescue after claimed revocation cleans credential without replaying unknown effect", %{
    account: account
  } do
    %{operation_id: id} = Mail.disconnect!(account.id, actor: @owner)
    Monolith.TestMail.response({:block_revoke, self()})
    worker = spawn(fn -> perform_job(DisconnectWorker, %{operation_id: id}) end)
    assert_receive {:revocation_blocked, ^worker}, 2_000
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert :ok = perform_job(DisconnectWorker, %{operation_id: id})
    assert :ok = perform_job(DisconnectWorker, %{operation_id: id})

    assert %{remote: :uncertain, revoked: false, credentials_removed: true} =
             Mail.disconnect_status!(account.id, actor: @owner)

    assert [{:revoke, "distinctive-private-cleanup-token"}] = Monolith.TestMail.calls()
    persisted = Ash.get!(Disconnection, id, actor: @owner)
    refute inspect(persisted) =~ "distinctive-private-cleanup-token"
    jobs = all_enqueued(worker: DisconnectWorker)
    assert Enum.all?(jobs, &(&1.args == %{"operation_id" => id}))
  end

  for failure <- [:raise, :throw] do
    test "#{failure} during revocation reports uncertainty and removes credentials without replay",
         %{account: account, workspace: workspace} do
      secret = "distinctive-private-revocation-#{unquote(failure)}"
      Monolith.TestMail.response({unquote(failure), secret})
      %{operation_id: id} = Mail.disconnect!(account.id, actor: @owner)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = perform_job(DisconnectWorker, %{operation_id: id})
          assert :ok = perform_job(DisconnectWorker, %{operation_id: id})

          assert %{
                   operation_id: ^id,
                   state: :complete,
                   local_removed: true,
                   remote: :uncertain,
                   revoked: false,
                   credentials_removed: true
                 } =
                   Mail.disconnect_status!(account.id, actor: @owner)

          assert %{
                   operation_id: ^id,
                   state: :complete,
                   remote: :uncertain,
                   credentials_removed: true
                 } = Mail.disconnect!(account.id, actor: @owner)
        end)

      assert {:error, :not_found} = Monolith.TestMailVault.get(account.id)
      assert Mail.workspace_accounts!(workspace.id, actor: @owner) == []

      assert %{status: :disconnected, last_error: nil} =
               Mail.get_account!(account.id, actor: @owner)

      assert [{:revoke, "distinctive-private-cleanup-token"}] = Monolith.TestMail.calls()

      public = Mail.disconnect_status!(account.id, actor: @owner)
      persisted = Ash.get!(Disconnection, id, actor: @owner)
      jobs = all_enqueued(worker: DisconnectWorker)
      assert Enum.all?(jobs, &(&1.args == %{"operation_id" => id}))

      for private <- [secret, "distinctive-private-cleanup-token"] do
        refute inspect({public, persisted, jobs}) =~ private
        refute log =~ private
      end
    end
  end

  test "reconnect supersedes queued cleanup without touching replacement credential", %{
    workspace: workspace,
    account: account
  } do
    %{operation_id: id} = Mail.disconnect!(account.id, actor: @owner)

    {:ok, replacement} =
      Access.accept(
        workspace.id,
        %{subject: account.subject, email: account.email},
        "new-private-token"
      )

    assert :ok = perform_job(DisconnectWorker, %{operation_id: id})
    assert {:ok, "new-private-token"} = Monolith.TestMailVault.get(account.id)
    assert Mail.get_account!(account.id, actor: @owner).generation == replacement.generation

    assert %{state: :superseded, credentials: :superseded, remote: :unavailable} =
             Mail.disconnect_status!(account.id, actor: @owner)

    assert Monolith.TestMail.calls() == []
  end

  test "repeated admission coalesces cleanup and refuses unauthorized callers", %{
    account: account
  } do
    assert {:error, _} = Mail.disconnect(account.id)
    %{operation_id: id} = Mail.disconnect!(account.id, actor: @owner)
    assert %{operation_id: ^id} = Mail.disconnect!(account.id, actor: @owner)
    assert :ok = perform_job(DisconnectWorker, %{operation_id: id})
    assert :ok = perform_job(DisconnectWorker, %{operation_id: id})

    completed = Mail.disconnect_status!(account.id, actor: @owner)
    jobs = all_enqueued(worker: DisconnectWorker)
    assert %{state: :complete, remote: :revoked, credentials_removed: true} = completed
    assert Mail.disconnect!(account.id, actor: @owner) == completed
    assert Mail.disconnect_status!(account.id, actor: @owner) == completed
    assert all_enqueued(worker: DisconnectWorker) == jobs
    assert {:error, :not_found} = Monolith.TestMailVault.get(account.id)
    assert [{:revoke, _}] = Monolith.TestMail.calls()
  end

  test "missing cleanup status is safe and an unknown job has no provider effect", %{
    account: account
  } do
    assert Mail.disconnect_status!(account.id, actor: @owner) == %{state: :unavailable}
    assert {:error, _} = Mail.disconnect_status(account.id)
    assert {:error, _} = Mail.disconnect_status(Ash.UUID.generate(), actor: @owner)
    assert :ok = perform_job(DisconnectWorker, %{operation_id: Ash.UUID.generate()})
    assert Monolith.TestMail.calls() == []
    assert {:ok, "distinctive-private-cleanup-token"} = Monolith.TestMailVault.get(account.id)
    assert Mail.get_account!(account.id, actor: @owner).status == :ready
  end
end
