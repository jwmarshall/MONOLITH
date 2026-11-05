defmodule Lovelace.MailConnectionBoundariesTest.Vault do
  @moduledoc false
  use Agent

  def start_link(_),
    do:
      Agent.start_link(fn -> %{tokens: %{}, read: :normal, write: :normal, calls: []} end,
        name: __MODULE__
      )

  def mode(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
  def tokens, do: Agent.get(__MODULE__, & &1.tokens)
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def reset_calls, do: Agent.update(__MODULE__, &Map.put(&1, :calls, []))

  def get(id) do
    Agent.get_and_update(__MODULE__, fn state ->
      result =
        case state.read do
          :normal ->
            stored_token(state.tokens, id)

          result ->
            result
        end

      {result, %{state | calls: [{:get, id} | state.calls]}}
    end)
  end

  def put(id, token) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | calls: [{:put, id} | state.calls]}

      case state.write do
        :normal -> {:ok, %{state | tokens: Map.put(state.tokens, id, token)}}
        result -> {result, state}
      end
    end)
  end

  def delete(id),
    do: Agent.update(__MODULE__, &%{&1 | tokens: Map.delete(&1.tokens, id)})

  defp stored_token(tokens, id) do
    case Map.fetch(tokens, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end
end

defmodule Lovelace.MailConnectionBoundariesTest.RaisingProvider do
  @moduledoc false
  def refresh(_), do: raise("synthetic private refresh credential")
end

defmodule Lovelace.MailConnectionBoundariesTest do
  use Lovelace.DataCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite

  alias Lovelace.Mail
  alias Lovelace.Mail.{Connections, PollWorker}
  alias Lovelace.MailConnectionBoundariesTest.{RaisingProvider, Vault}

  @owner %{role: :local_owner}

  setup do
    start_supervised!(Vault)
    {:ok, _} = Lovelace.TestMail.start()
    keys = [:gmail_vault, :gmail_provider]
    previous = Keyword.take(Application.get_all_env(:lovelace), keys)
    Application.put_env(:lovelace, :gmail_vault, Vault)
    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)

    on_exit(fn ->
      for key <- keys do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:lovelace, key, value)
          :error -> Application.delete_env(:lovelace, key)
        end
      end
    end)

    workspace = Lovelace.Workspaces.create_workspace!("Connection boundary", actor: @owner)
    identity = %{subject: "boundary-subject", email: "boundary@example.invalid"}
    {:ok, account} = Connections.accept(workspace.id, identity, "synthetic-prior-refresh")
    account = Mail.get_account!(account.id, actor: @owner)
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "mail:#{account.id}")
    Vault.reset_calls()

    %{
      workspace: workspace,
      identity: identity,
      account: account,
      tokens: Vault.tokens(),
      jobs: all_enqueued(worker: PollWorker)
    }
  end

  test "invalid consent is rejected and missing workspaces compensate without changing connections",
       context do
    for {token, capability} <- [{"", :gmail}, {nil, :gmail}, {"replacement", :unknown}] do
      assert {:error, :reconnect} =
               Connections.accept(context.workspace.id, context.identity, token, capability)
    end

    assert Vault.calls() == []
    assert_unchanged(context)

    assert {:error, :unavailable} =
             Connections.accept(Ash.UUID.generate(), context.identity, "replacement")

    assert Vault.calls() == [
             {:get, context.account.id},
             {:put, context.account.id},
             {:put, context.account.id}
           ]

    assert_unchanged(context)
    Vault.reset_calls()

    assert {:error, :unavailable} =
             Connections.accept(
               context.workspace.id,
               %{subject: nil, email: "x@example.invalid"},
               "replacement"
             )

    assert Vault.calls() == []
    assert_unchanged(context)
  end

  test "an unexpected vault read result cannot be mistaken for an absent credential", context do
    Vault.mode(:read, {:private_payload, "synthetic credential"})

    assert {:error, {:keychain, :unavailable}} =
             Connections.accept(context.workspace.id, context.identity, "replacement")

    assert Vault.calls() == [{:get, context.account.id}]
    assert_unchanged(context)
  end

  test "rejected vault replacement never commits account changes or schedules publication",
       context do
    for {response, reason} <- [
          {{:error, :locked}, :locked},
          {{:private_payload, "synthetic credential"}, :unavailable}
        ] do
      Vault.reset_calls()
      Vault.mode(:write, response)

      assert {:error, {:keychain, ^reason}} =
               Connections.accept(context.workspace.id, context.identity, "replacement")

      assert Vault.calls() == [
               {:get, context.account.id},
               {:put, context.account.id}
             ]

      assert_unchanged(context)
    end
  end

  test "stale, disconnected and nonexistent accounts cannot refresh provider tokens", context do
    stale = %{context.account | generation: Ash.UUID.generate()}
    unknown = %{context.account | id: Ash.UUID.generate()}

    assert {:error, :unavailable} = Connections.access_token(stale)
    assert {:error, :unavailable} = Connections.access_token(unknown)

    Mail.update_account!(
      context.account,
      %{status: :disconnected, expected_generation: context.account.generation},
      actor: @owner
    )

    assert {:error, :unavailable} = Connections.access_token(context.account)
    assert Vault.calls() == []
    assert Lovelace.TestMail.calls() == []
  end

  test "missing credentials require reconnection while unreadable credentials remain keychain failures",
       context do
    for {response, reason} <- [
          {{:error, :not_found}, :reconnect},
          {{:error, :locked}, :keychain},
          {{:private_payload, "synthetic credential"}, :keychain}
        ] do
      Vault.mode(:read, response)
      assert {:error, ^reason} = Connections.access_token(context.account)
      assert Lovelace.TestMail.calls() == []
      assert_unchanged(context)
    end
  end

  test "malformed refresh results and provider exceptions cannot escape as access credentials",
       context do
    Lovelace.TestMail.response({:private_payload, "synthetic provider secret"})
    assert {:error, :keychain} = Connections.access_token(context.account)
    assert Vault.tokens() == context.tokens

    Application.put_env(:lovelace, :gmail_provider, RaisingProvider)
    assert {:error, :unavailable} = Connections.access_token(context.account)
    assert_unchanged(context)
  end

  test "a refresh token rotation must persist before its access token can be released", context do
    Lovelace.TestMail.response(
      {:ok, %{access_token: "synthetic-access", refresh_token: "rotated-refresh"}}
    )

    Vault.mode(:write, {:error, :locked})

    assert {:error, :keychain} = Connections.access_token(context.account)
    assert Vault.tokens() == context.tokens
    assert Mail.get_account!(context.account.id, actor: @owner) == context.account

    Vault.mode(:write, :normal)
    assert {:ok, "synthetic-access"} = Connections.access_token(context.account)
    assert Vault.tokens()[context.account.id] == "rotated-refresh"
  end

  defp assert_unchanged(context) do
    assert Vault.tokens() == context.tokens
    assert Mail.get_account!(context.account.id, actor: @owner) == context.account
    assert [%{account_id: id}] = Mail.workspace_accounts!(context.workspace.id, actor: @owner)
    assert id == context.account.id
    assert all_enqueued(worker: PollWorker) == context.jobs
    refute_receive {:mail_changed, _}
  end
end
