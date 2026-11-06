defmodule Lovelace.MailCredentialCheckTest do
  use Lovelace.DataCase, async: false

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias Lovelace.Google.Access
  alias Lovelace.Mail
  alias Lovelace.Mail.CacheEntry

  @owner %{role: :local_owner}
  @private "synthetic-private-credential-diagnostic"

  defmodule FakeIO do
    @moduledoc false
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{results: %{}, calls: []} end, name: __MODULE__)

    def result(id, result), do: Agent.update(__MODULE__, &put_in(&1, [:results, id], result))
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def get(id) do
      response =
        Agent.get_and_update(__MODULE__, fn state ->
          {Map.get(state.results, id, {:error, :not_found}),
           %{state | calls: [{:get, id} | state.calls]}}
        end)

      respond(response)
    end

    def put(id, _token), do: unexpected({:put, id})
    def delete(id), do: unexpected({:delete, id})
    def refresh(_token), do: unexpected(:refresh)
    def revoke(_token), do: unexpected(:revoke)
    def inbox(_token, _page), do: unexpected(:inbox)
    def inbox_unread(_token), do: unexpected(:inbox_unread)
    def search(_token, _query, _page), do: unexpected(:search)
    def thread(_token, _id), do: unexpected(:thread)

    defp unexpected(call) do
      Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})
      {:error, :unavailable}
    end

    defp respond({:raise, message}), do: raise(message)
    defp respond({:throw, value}), do: throw(value)
    defp respond({:exit, value}), do: exit(value)

    defp respond({:wait, owner, result}) do
      send(owner, {:credential_read_waiting, self()})

      receive do
        :release -> result
      after
        5_000 -> {:error, :timeout}
      end
    end

    defp respond(result), do: result
  end

  setup do
    start_supervised!(FakeIO)
    previous = Keyword.take(Application.get_all_env(:lovelace), [:gmail_provider, :gmail_vault])
    Application.put_env(:lovelace, :gmail_provider, FakeIO)
    Application.put_env(:lovelace, :gmail_vault, FakeIO)

    on_exit(fn ->
      for key <- [:gmail_provider, :gmail_vault] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:lovelace, key, value)
          :error -> Application.delete_env(:lovelace, key)
        end
      end
    end)

    workspace = Lovelace.Workspaces.create_workspace!("Credential checks", actor: @owner)
    a = account("a")
    b = account("b")

    for account <- [a, b] do
      Mail.attach_account!(%{workspace_id: workspace.id, account_id: account.id}, actor: @owner)
      seed_cache(account)
      Phoenix.PubSub.subscribe(Lovelace.PubSub, "mail:#{account.id}")
    end

    %{workspace: workspace, a: a, b: b}
  end

  test "safe vault categories are read-only observations, not Gmail health recovery", ctx do
    a =
      set_status(ctx.a, %{
        status: :reconnect,
        last_error: :keychain,
        last_success_at: ~U[2026-01-01 12:00:00Z],
        next_poll_at: ~U[2026-01-02 12:00:00Z],
        inbox_unread_count: 7,
        inbox_unread_recent_count: 2,
        inbox_unread_at: ~U[2026-01-01 11:00:00Z],
        inbox_unread_error: :provider
      })

    before = snapshot(ctx)

    cases = [
      {{:ok, @private}, :accessible},
      {{:error, :locked}, :locked},
      {{:error, :timeout}, :timeout},
      {{:error, :not_found}, :not_found},
      {{:error, :invalid_account}, :invalid_account},
      {{:error, :invalid_value}, :invalid_value},
      {{:error, :unavailable}, :unavailable}
    ]

    for {response, expected} <- cases do
      FakeIO.result(a.id, response)
      assert {:ok, %{status: ^expected} = result} = check(a)
      assert Map.keys(result) == [:status]
      refute inspect(result) =~ @private
      assert snapshot(ctx) == before
      refute_received {:mail_changed, _}
    end

    assert FakeIO.calls() == List.duplicate({:get, a.id}, length(cases))
  end

  test "unknown, malformed and exceptional vault responses are sanitized", %{a: a} = ctx do
    before = snapshot(ctx)

    responses = [
      {:error, @private},
      {:error, %{private: @private}},
      {:error, :unknown_vault_failure},
      {:ok, nil},
      {:ok, 42},
      {:ok, %{token: @private}},
      nil,
      :ok,
      {:raise, @private},
      {:throw, @private},
      {:exit, @private}
    ]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for response <- responses do
          FakeIO.result(a.id, response)
          assert {:ok, %{status: :unavailable} = result} = check(a)
          assert Map.keys(result) == [:status]
          refute inspect(result) =~ @private
        end
      end)

    refute log =~ @private
    assert FakeIO.calls() == List.duplicate({:get, a.id}, length(responses))
    assert snapshot(ctx) == before
  end

  test "only the local owner can check credentials, including against an explicitly scoped account",
       %{a: a} = ctx do
    FakeIO.result(a.id, {:ok, @private})
    before = snapshot(ctx)

    for actor <- [nil, %{}, %{role: :mail_service, account_id: a.id}, %{role: :visitor}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.check_credentials(a.id, a.generation, actor: actor)
    end

    assert FakeIO.calls() == []
    assert snapshot(ctx) == before
  end

  test "the explicit account selects its own vault entry even when provider cache keys match",
       %{a: a, b: b} = ctx do
    FakeIO.result(a.id, {:error, :locked})
    FakeIO.result(b.id, {:ok, @private})
    before = snapshot(ctx)

    assert {:ok, %{status: :locked}} = check(a)
    assert {:ok, %{status: :accessible}} = check(b)
    assert {:ok, %{status: :locked}} = check(a)
    assert FakeIO.calls() == [{:get, a.id}, {:get, b.id}, {:get, a.id}]
    assert snapshot(ctx) == before
  end

  test "missing accounts, stale generations and disconnected accounts never read the vault",
       %{a: a, b: b} do
    FakeIO.result(a.id, {:ok, @private})
    set_status(b, %{status: :disconnected})
    missing_id = Ash.UUID.generate()
    stale_generation = Ash.UUID.generate()

    assert {:ok, %{status: :changed}} =
             Mail.check_credentials(missing_id, a.generation, actor: @owner)

    assert {:ok, %{status: :changed}} =
             Mail.check_credentials(a.id, stale_generation, actor: @owner)

    assert {:ok, %{status: :changed}} = check(b)
    assert FakeIO.calls() == []
  end

  test "a local credential read does not wait behind the account's provider coordination lock",
       %{a: a} do
    FakeIO.result(a.id, {:ok, @private})

    Access.serial(a.id, fn ->
      task = async_check(a)
      assert {:ok, {:ok, %{status: :accessible}}} = Task.yield(task, 2_000)
    end)

    assert FakeIO.calls() == [{:get, a.id}]
  end

  test "a reconnect while the vault read is pending fences the old observation", %{a: a} do
    FakeIO.result(a.id, {:wait, self(), {:ok, @private}})
    task = async_check(a)
    assert_receive {:credential_read_waiting, worker}, 2_000

    reconnected =
      Mail.save_connection!(
        %{id: a.id, subject: a.subject, email: a.email, generation: Ash.UUID.generate()},
        actor: @owner
      )

    send(worker, :release)
    assert {:ok, %{status: :changed}} = Task.await(task)
    assert Mail.get_account!(a.id, actor: @owner).generation == reconnected.generation
    assert FakeIO.calls() == [{:get, a.id}]
  end

  test "a disconnect while the vault read is pending fences even a safe error", %{a: a} do
    FakeIO.result(a.id, {:wait, self(), {:error, :locked}})
    task = async_check(a)
    assert_receive {:credential_read_waiting, worker}, 2_000
    set_status(a, %{status: :disconnected})
    send(worker, :release)

    assert {:ok, %{status: :changed}} = Task.await(task)
    assert Mail.get_account!(a.id, actor: @owner).status == :disconnected
    assert FakeIO.calls() == [{:get, a.id}]
  end

  defp check(account),
    do: Mail.check_credentials(account.id, account.generation, actor: @owner)

  defp async_check(account) do
    task =
      Task.async(fn ->
        receive do
          :go -> check(account)
        end
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :go)
    task
  end

  defp account(name) do
    Mail.save_connection!(
      %{
        id: Ash.UUID.generate(),
        subject: "credential-check-#{name}",
        email: "credential-check-#{name}@example.test",
        generation: Ash.UUID.generate()
      },
      actor: @owner
    )
  end

  defp set_status(account, attrs) do
    Mail.update_account!(account, Map.put(attrs, :expected_generation, account.generation),
      actor: @owner
    )
  end

  defp seed_cache(account) do
    CacheEntry
    |> Ash.Changeset.for_create(
      :store,
      %{
        account_id: account.id,
        key: "same-provider-thread",
        generation: account.generation,
        payload: %{"subject" => "Synthetic cached #{account.id}"},
        bytes: 64,
        fetched_at: ~U[2026-01-01 12:00:00Z],
        expires_at: ~U[2026-01-08 12:00:00Z]
      },
      actor: @owner
    )
    |> Ash.create!()
  end

  defp snapshot(ctx) do
    %{
      accounts: Enum.map(Mail.list_accounts!(actor: @owner), &attributes/1),
      cache:
        Enum.map([ctx.a, ctx.b], fn account ->
          CacheEntry
          |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
          |> Ash.read!()
          |> Enum.map(&attributes/1)
        end),
      memberships:
        ctx.workspace.id
        |> Mail.workspace_accounts!(actor: @owner)
        |> Enum.map(&attributes/1)
        |> Enum.sort_by(& &1.id),
      jobs: Repo.all(from job in Oban.Job, order_by: job.id)
    }
  end

  defp attributes(%resource{} = record) do
    Map.take(record, Enum.map(Info.attributes(resource), & &1.name))
  end
end
