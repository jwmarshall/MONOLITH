defmodule Monolith.HomeSummaryTest do
  use Monolith.DataCase, async: false

  alias Monolith.GitHub.{Organization, WorkspaceOrganization}
  alias Monolith.{Home, Mail, Workspaces}

  @owner %{role: :local_owner}
  @github_service %{role: :github_service}

  defmodule NoExternalAccess do
    @moduledoc false
    def get(_id), do: raise("Summary must not read credentials")
    def refresh(_token), do: raise("Summary must not refresh credentials")
    def inbox(_token, _page), do: raise("Summary must not fetch mail")
    def snapshot(_token, _repositories), do: raise("Summary must not fetch GitHub")
  end

  setup do
    keys = [:gmail_provider, :gmail_vault, :github_provider, :github_keychain]
    previous = Map.new(keys, &{&1, Application.fetch_env(:monolith, &1)})
    Enum.each(keys, &Application.put_env(:monolith, &1, NoExternalAccess))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:monolith, key, value)
        {key, :error} -> Application.delete_env(:monolith, key)
      end)
    end)

    :ok
  end

  test "owner summary composes scoped health and labels without credentials, caches or providers" do
    shared = Workspaces.create_workspace!("Shared", actor: @owner)
    personal = Workspaces.create_workspace!("Personal", actor: @owner)
    empty = Workspaces.create_workspace!("Empty", actor: @owner)
    healthy = account("healthy")
    reconnect = account("reconnect")
    unattached = account("unattached")

    for {workspace, account} <- [
          {shared, healthy},
          {personal, healthy},
          {shared, reconnect}
        ] do
      Mail.attach_account!(%{workspace_id: workspace.id, account_id: account.id}, actor: @owner)
    end

    reconnect =
      Mail.update_account!(
        reconnect,
        %{expected_generation: reconnect.generation, status: :reconnect, last_error: :reconnect},
        actor: @owner
      )

    org = organization("synthetic-owner", :reauthorization, :reconnect)
    attach_organization(personal, org)

    assert {:ok, summary} = Home.summary(actor: @owner)
    refute summary.accounts_error?
    assert Enum.map(summary.workspaces, & &1.id) == [shared.id, personal.id, empty.id]

    assert Enum.sort(summary.subscription_ids) ==
             Enum.sort([healthy.id, reconnect.id, unattached.id])

    accounts = Map.new(summary.accounts, &{&1.id, &1})
    assert accounts[healthy.id].workspaces == ["Personal", "Shared"]
    assert accounts[unattached.id].workspaces == []
    assert accounts[healthy.id].inbox_unread_count == nil
    refute Map.has_key?(accounts[healthy.id], :subject)
    refute Map.has_key?(accounts[healthy.id], :generation)
    refute Map.has_key?(accounts[healthy.id], :workspace_ids)

    assert summary.workspace_health[shared.id] == %{
             total: 2,
             google_accounts: 2,
             github_installations: 0,
             problems: [Map.take(reconnect, [:id, :email, :status, :last_error])]
           }

    assert summary.workspace_health[personal.id] == %{
             total: 2,
             google_accounts: 1,
             github_installations: 1,
             problems: [
               %{
                 id: org.id,
                 email: "GitHub · synthetic-owner",
                 status: :reauthorization,
                 last_error: :reconnect
               }
             ]
           }

    assert summary.workspace_health[empty.id] == %{
             total: 0,
             google_accounts: 0,
             github_installations: 0,
             problems: []
           }
  end

  test "Home and Mail summary actions reject missing, provider-service and incorrect owner actors" do
    for options <- [
          [],
          [actor: %{}],
          [actor: %{role: :mail_service}],
          [actor: %{role: "local_owner"}]
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = Home.summary(options)
      assert {:error, %Ash.Error.Forbidden{}} = Mail.home_summary(options)
    end
  end

  test "disconnected mail disappears from Home without manufacturing healthy membership metadata" do
    workspace = Workspaces.create_workspace!("Existing membership", actor: @owner)
    account = account("disconnected")
    Mail.attach_account!(%{workspace_id: workspace.id, account_id: account.id}, actor: @owner)

    Mail.update_account!(
      account,
      %{expected_generation: account.generation, status: :disconnected},
      actor: @owner
    )

    assert {:ok, summary} = Home.summary(actor: @owner)
    assert summary.accounts == []
    assert summary.workspace_health[workspace.id].total == 1
    assert [%{id: id, status: :disconnected}] = summary.workspace_health[workspace.id].problems
    assert id == account.id
  end

  test "account overflow is unavailable, not a truncated healthy summary" do
    workspace = Workspaces.create_workspace!("Bounded", actor: @owner)
    Enum.each(1..257, &account("bounded-#{&1}"))

    assert {:error, _} = Mail.home_summary(actor: @owner)
    assert {:ok, summary} = Home.summary(actor: @owner)
    assert summary.accounts_error?
    assert summary.accounts == []
    assert summary.subscription_ids == []
    assert summary.workspace_health[workspace.id] == nil
  end

  test "workspace overflow fails honestly rather than silently hiding saved destinations" do
    Enum.each(1..257, &Workspaces.create_workspace!("Workspace #{&1}", actor: @owner))
    assert {:error, _} = Home.summary(actor: @owner)
  end

  defp account(name) do
    Mail.save_connection!(
      %{
        id: Ash.UUID.generate(),
        subject: "home-summary-#{name}",
        email: "#{name}@example.test",
        generation: Ash.UUID.generate()
      },
      actor: @owner
    )
  end

  defp organization(login, status, error) do
    Organization
    |> Ash.Changeset.for_create(
      :connect,
      %{
        id: Ash.UUID.generate(),
        github_id: "home-summary-#{login}",
        login: login,
        generation: Ash.UUID.generate(),
        next_poll_at: DateTime.utc_now(),
        status: status,
        last_error: error
      },
      actor: @github_service
    )
    |> Ash.create!()
  end

  defp attach_organization(workspace, organization) do
    WorkspaceOrganization
    |> Ash.Changeset.for_create(
      :attach,
      %{workspace_id: workspace.id, organization_id: organization.id},
      actor: @github_service
    )
    |> Ash.create!()
  end
end
