defmodule Lovelace.GitHubAuthTest do
  use LovelaceWeb.ConnCase, async: false
  alias Lovelace.GitHub.{Auth, Operations}
  alias Lovelace.Owner.Actions
  alias Lovelace.TestGitHub

  setup %{conn: conn} do
    start_supervised!({TestGitHub, []})

    settings = [
      github_provider: TestGitHub,
      github_keychain: Lovelace.TestGitHubKeychain,
      github: [client_id: "Iv1.synthetic", app_slug: "lovelace-synthetic"]
    ]

    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:lovelace, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:lovelace, key, value) end)
    session = authenticate_owner(conn) |> get_session(:owner_session_token)

    on_exit(fn ->
      Auth.cancel(session)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lovelace, key)
        {key, value} -> Application.put_env(:lovelace, key, value)
      end)
    end)

    %{session: session}
  end

  test "cancel and restart cannot overlap device-code requests", %{session: session} do
    TestGitHub.configure(device_response: {:wait, self(), {:error, :provider}})
    assert :ok = Auth.begin(session)
    assert_receive {:github_waiting, worker}
    monitor = Process.monitor(worker)
    assert :ok = Auth.cancel(session)
    assert {:error, :busy} = Auth.begin(session)
    send(worker, :continue)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    assert Auth.status(Actions.digest(session)) == %{status: :idle}
    assert TestGitHub.state().calls == [{:device_code, "Iv1.synthetic"}]
  end

  test "cancelling an in-flight exchange fences its later credential publication", %{
    session: session
  } do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    assert :ok = Auth.begin(session)
    assert_receive {:github_waiting, worker}, 7_000
    monitor = Process.monitor(worker)
    assert :ok = Auth.cancel(session)
    send(worker, :continue)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert TestGitHub.state().tokens == %{}

    assert %{organizations: [], connections: []} =
             Lovelace.GitHub.directory!(actor: %{role: :local_owner})

    assert Auth.status(Actions.digest(session)) == %{status: :idle}
  end

  test "revoking the owner session during exchange refuses the final commit", %{session: session} do
    TestGitHub.configure(exchange_response: {:wait, self(), {:ok, TestGitHub.bundle()}})
    assert :ok = Auth.begin(session)
    assert_receive {:github_waiting, worker}, 7_000
    monitor = Process.monitor(worker)
    Lovelace.Owner.logout(session)
    send(worker, :continue)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    assert TestGitHub.state().tokens == %{}

    assert %{organizations: [], connections: []} =
             Lovelace.GitHub.directory!(actor: %{role: :local_owner})
  end

  for operation <- [:disconnect_account, :disconnect] do
    test "#{operation} during device exchange cannot be undone by its delayed result", %{
      session: session
    } do
      assert {:ok, initial} = Operations.authorize(session, TestGitHub.bundle())

      TestGitHub.configure(
        exchange_response: {:wait, self(), {:ok, TestGitHub.bundle("replacement")}}
      )

      assert :ok = Auth.begin(session)
      assert_receive {:github_waiting, worker}, 7_000
      monitor = Process.monitor(worker)

      id =
        if unquote(operation) == :disconnect_account,
          do: initial.connection.id,
          else: hd(initial.organizations).id

      assert {:ok, _} =
               apply(Lovelace.GitHub, unquote(operation), [id, [actor: %{role: :local_owner}]])

      tokens = TestGitHub.state().tokens
      send(worker, :continue)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
      assert TestGitHub.state().tokens == tokens
      directory = Lovelace.GitHub.directory!(actor: %{role: :local_owner})

      records =
        if unquote(operation) == :disconnect_account,
          do: directory.connections,
          else: directory.organizations

      assert Enum.find(records, &(&1.id == id)).status == :disconnected
      assert Auth.status(Actions.digest(session)).status == :failed
    end
  end

  test "successful device authorization discovers personal and organization installations without auto-attaching",
       %{session: session} do
    assert :ok = Auth.begin(session)
    status = await_status(session, :connected)
    assert status == %{status: :connected}
    directory = Lovelace.GitHub.directory!(actor: %{role: :local_owner})
    assert Enum.sort(Enum.map(directory.organizations, & &1.owner_type)) == [:organization, :user]
    assert directory.memberships == []
    [connection] = directory.connections
    assert {:ok, encoded} = Lovelace.TestGitHubKeychain.get(connection.id)
    assert Jason.decode!(encoded)["access_token"] == TestGitHub.bundle().access_token
    refute inspect(directory) =~ TestGitHub.bundle().access_token
    assert {:ok, _} = Operations.access_token(connection.id)
    assert {:error, :already_authorized} = Auth.cancel(session)
    assert Auth.status(Actions.digest(session)) == %{status: :connected}
  end

  defp await_status(session, status, remaining \\ 800)
  defp await_status(_, _, 0), do: flunk("GitHub authorization did not reach expected state")

  defp await_status(session, status, remaining) do
    case Auth.status(Actions.digest(session)) do
      %{status: ^status} = result ->
        result

      %{status: :failed} = result ->
        flunk("Authorization failed: #{inspect(result)}")

      _ ->
        Process.sleep(10)
        await_status(session, status, remaining - 1)
    end
  end
end
