defmodule Lovelace.MailCompensationTest.Vault do
  @moduledoc false

  def start do
    Agent.start_link(fn -> %{tokens: %{}, calls: [], failure: nil} end, name: __MODULE__)
  end

  def failure(mode), do: Agent.update(__MODULE__, &Map.put(&1, :failure, mode))
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def get(id) do
    Agent.get(__MODULE__, fn state ->
      case Map.fetch(state.tokens, id) do
        {:ok, token} -> {:ok, token}
        :error -> {:error, :not_found}
      end
    end)
  end

  def put(id, token) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | calls: [{:put, id, token} | state.calls]}

      if state.failure == :restore and token == "synthetic-prior" do
        {{:error, :locked}, state}
      else
        {:ok, %{state | tokens: Map.put(state.tokens, id, token)}}
      end
    end)
  end

  def delete(id) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | calls: [{:delete, id} | state.calls]}

      if state.failure == :cleanup do
        {{:error, :locked}, state}
      else
        {:ok, %{state | tokens: Map.delete(state.tokens, id)}}
      end
    end)
  end
end

defmodule Lovelace.MailCompensationTest do
  use Lovelace.DataCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite

  alias Ecto.Adapters.SQL
  alias Lovelace.Mail
  alias Lovelace.Mail.{Connections, PollWorker}
  alias Lovelace.MailCompensationTest.Vault

  @owner %{role: :local_owner}

  setup do
    {:ok, _} = Vault.start()
    {:ok, _} = Lovelace.TestMail.start()
    previous = Keyword.take(Application.get_all_env(:lovelace), [:gmail_provider, :gmail_vault])
    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Vault)

    on_exit(fn ->
      for key <- [:gmail_provider, :gmail_vault] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:lovelace, key, value)
          :error -> Application.delete_env(:lovelace, key)
        end
      end
    end)

    workspace = Lovelace.Workspaces.create_workspace!("Compensation fixture", actor: @owner)
    other = Lovelace.Workspaces.create_workspace!("Shared compensation fixture", actor: @owner)

    {:ok, account} =
      Connections.accept(
        workspace.id,
        %{subject: "compensation-subject", email: "compensation@example.invalid"},
        "synthetic-prior"
      )

    assert {:ok, true} = Mail.link(other.id, account.id, actor: @owner)
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "mail:#{account.id}")

    %{
      workspace: workspace,
      other: other,
      account: Mail.get_account!(account.id, actor: @owner),
      jobs: all_enqueued(worker: PollWorker)
    }
  end

  test "persistence failure after vault replacement restores the exact prior credential",
       context do
    %{workspace: workspace, account: account} = context

    assert {:error, :unavailable} =
             Connections.accept(
               workspace.id,
               %{subject: account.subject, email: nil},
               "synthetic-replacement"
             )

    assert {:ok, "synthetic-prior"} = Vault.get(account.id)

    assert Enum.take(Vault.calls(), -2) == [
             {:put, account.id, "synthetic-replacement"},
             {:put, account.id, "synthetic-prior"}
           ]

    assert_unchanged(context)
  end

  test "persistence failure deletes replacement credentials when the prior token was absent",
       context do
    %{workspace: workspace, account: account} = context
    assert :ok = Vault.delete(account.id)

    assert {:error, :unavailable} =
             Connections.accept(
               workspace.id,
               %{subject: account.subject, email: nil},
               "synthetic-replacement"
             )

    assert {:error, :not_found} = Vault.get(account.id)

    assert Enum.take(Vault.calls(), -2) == [
             {:put, account.id, "synthetic-replacement"},
             {:delete, account.id}
           ]

    assert_unchanged(context)
  end

  test "a failed first connection leaves neither a new identity nor an orphan credential",
       context do
    assert {:error, :unavailable} =
             Connections.accept(
               context.workspace.id,
               %{subject: "new-invalid-identity", email: nil},
               "synthetic-new"
             )

    assert [{:put, id, "synthetic-new"}, {:delete, id}] = Enum.take(Vault.calls(), -2)
    assert {:error, :not_found} = Vault.get(id)
    assert {:ok, nil} = Mail.find_account("new-invalid-identity", actor: @owner)
    assert_unchanged(context)
  end

  test "membership failure after a valid identity upsert rolls back account changes", context do
    destination = Lovelace.Workspaces.create_workspace!("Rejected destination", actor: @owner)

    reject_membership(fn ->
      assert {:error, :unavailable} =
               Connections.accept(
                 destination.id,
                 %{subject: context.account.subject, email: "changed@example.invalid"},
                 "synthetic-replacement"
               )
    end)

    assert {:ok, "synthetic-prior"} = Vault.get(context.account.id)

    assert Enum.take(Vault.calls(), -2) == [
             {:put, context.account.id, "synthetic-replacement"},
             {:put, context.account.id, "synthetic-prior"}
           ]

    assert Mail.workspace_accounts!(destination.id, actor: @owner) == []
    assert_unchanged(context)
  end

  test "membership failure after creating a valid new identity rolls back the row and credential",
       context do
    destination = Lovelace.Workspaces.create_workspace!("Rejected new identity", actor: @owner)

    reject_membership(fn ->
      assert {:error, :unavailable} =
               Connections.accept(
                 destination.id,
                 %{subject: "valid-new-identity", email: "new-identity@example.invalid"},
                 "synthetic-new"
               )
    end)

    assert [{:put, id, "synthetic-new"}, {:delete, id}] = Enum.take(Vault.calls(), -2)
    assert {:error, :not_found} = Vault.get(id)
    assert {:ok, nil} = Mail.find_account("valid-new-identity", actor: @owner)
    assert Mail.workspace_accounts!(destination.id, actor: @owner) == []
    assert_unchanged(context)
  end

  test "failed restoration is an explicit rollback failure, not connection success", context do
    Vault.failure(:restore)
    assert_rollback_failure(context)
    assert {:ok, "synthetic-replacement"} = Vault.get(context.account.id)
    assert_unchanged(context)
  end

  test "failed cleanup of a previously absent credential is an explicit rollback failure",
       context do
    assert :ok = Vault.delete(context.account.id)
    Vault.failure(:cleanup)
    assert_rollback_failure(context)
    assert {:ok, "synthetic-replacement"} = Vault.get(context.account.id)
    assert_unchanged(context)
  end

  defp reject_membership(fun) do
    # Synthetic infrastructure fault: RAISE(ABORT) cancels this INSERT only, not
    # the preceding successful account upsert. Connections' outer transaction
    # must roll that write back. Both valid-email cases fail if it is removed.
    SQL.query!(
      Repo,
      "CREATE TEMP TRIGGER lovelace_reject_test_membership BEFORE INSERT ON workspace_gmail_accounts BEGIN SELECT RAISE(ABORT, 'synthetic membership failure'); END",
      [],
      log: false,
      telemetry_event: nil
    )

    try do
      fun.()
    after
      SQL.query!(Repo, "DROP TRIGGER IF EXISTS lovelace_reject_test_membership", [],
        log: false,
        telemetry_event: nil
      )
    end
  end

  defp assert_rollback_failure(context) do
    assert {:error, {:keychain, :rollback_failed}} =
             Connections.accept(
               context.workspace.id,
               %{subject: context.account.subject, email: nil},
               "synthetic-replacement"
             )
  end

  defp assert_unchanged(context) do
    assert Mail.get_account!(context.account.id, actor: @owner) == context.account
    assert [%{account_id: id}] = Mail.workspace_accounts!(context.workspace.id, actor: @owner)
    assert id == context.account.id
    assert [%{account_id: ^id}] = Mail.workspace_accounts!(context.other.id, actor: @owner)
    assert all_enqueued(worker: PollWorker) == context.jobs
    assert length(Mail.list_accounts!(actor: @owner)) == 1
    assert Lovelace.TestMail.calls() == []
    refute_receive {:mail_changed, _}
  end
end
