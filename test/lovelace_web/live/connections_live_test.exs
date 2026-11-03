defmodule LovelaceWeb.ConnectionsLiveTest do
  use LovelaceWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ash.Resource.Info
  alias Lovelace.Mail
  alias Lovelace.Mail.{Account, ViewData}
  alias Lovelace.TestSupport.GeminiVault
  alias Lovelace.Workspaces
  alias LovelaceWeb.HomeLive

  @owner %{role: :local_owner}

  defmodule FakeIO do
    @moduledoc false

    def start_link(owner) do
      Agent.start_link(fn -> %{owner: owner, calls: [], blocked: [], get_results: %{}} end,
        name: __MODULE__
      )
    end

    def child_spec(owner), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [owner]}}

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def block(operation), do: Agent.update(__MODULE__, &%{&1 | blocked: [operation]})
    def unblock, do: Agent.update(__MODULE__, &%{&1 | blocked: []})

    def get_result(id, result),
      do: Agent.update(__MODULE__, &put_in(&1, [:get_results, id], result))

    def get(id) do
      result = Agent.get(__MODULE__, &Map.get(&1.get_results, id, {:ok, "refresh:" <> id}))
      result = record({:get, id}, result)

      case result do
        {:raise, message} -> raise message
        {:throw, value} -> throw(value)
        _ -> result
      end
    end

    def put(id, _token), do: record({:put, id}, :ok)
    def delete(id), do: record({:delete, id}, :ok)

    def refresh("refresh:" <> id),
      do: record({:refresh, id}, {:ok, %{access_token: "access:" <> id}})

    def revoke("refresh:" <> id), do: record({:revoke, id}, :ok)

    def inbox("access:" <> id, token),
      do: record({:inbox, id, token}, page(id))

    def search("access:" <> id, query, token),
      do: record({:search, id, query, token}, page(id))

    def thread("access:" <> id, thread_id),
      do: record({:thread, id, thread_id}, {:ok, %{"messages" => []}})

    defp page(id) do
      {:ok,
       %{
         "threads" => [
           %{
             "id" => "shared-thread",
             "subject" => "Synthetic inbox #{id}",
             "from" => "sender@example.test",
             "snippet" => "Synthetic snippet",
             "date" => "Yesterday",
             "unread" => false
           }
         ],
         "next_page_token" => nil
       }}
    end

    defp record(call, result) do
      {owner, blocked} =
        Agent.get_and_update(__MODULE__, fn state ->
          {{state.owner, elem(call, 0) in state.blocked}, %{state | calls: [call | state.calls]}}
        end)

      if blocked do
        send(owner, {:fake_blocked, self(), call})

        receive do
          :release -> result
        after
          5_000 -> {:error, :provider}
        end
      else
        result
      end
    end
  end

  setup %{conn: conn} do
    start_supervised!({FakeIO, self()})
    fake_gemini_vault()
    previous_provider = Application.fetch_env(:lovelace, :gmail_provider)
    previous_vault = Application.fetch_env(:lovelace, :gmail_vault)
    Application.put_env(:lovelace, :gmail_provider, FakeIO)
    Application.put_env(:lovelace, :gmail_vault, FakeIO)

    on_exit(fn ->
      restore(:gmail_provider, previous_provider)
      restore(:gmail_vault, previous_vault)
    end)

    workspace = Workspaces.create_workspace!("Alpha workspace", actor: @owner)
    other = Workspaces.create_workspace!("Beta workspace", actor: @owner)
    healthy = account("alpha-healthy")

    reconnect =
      account("alpha-reconnect") |> status(%{status: :reconnect, last_error: :reconnect})

    limited = account("beta-limited") |> status(%{last_error: :rate_limited})
    available = account("unattached")

    for {space, connection} <- [
          {workspace, healthy},
          {workspace, reconnect},
          {other, healthy},
          {other, limited}
        ] do
      # Reconnect fixtures represent links established before access expired.
      Mail.attach_account!(%{workspace_id: space.id, account_id: connection.id}, actor: @owner)
    end

    %{
      conn: authenticate_owner(conn),
      workspace: workspace,
      other: other,
      healthy: healthy,
      reconnect: reconnect,
      limited: limited,
      available: available
    }
  end

  test "workspace cards expose only their own problem metadata and separate native menus", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    alpha = "#workspaces-#{ctx.workspace.id}"
    beta = "#workspaces-#{ctx.other.id}"

    assert has_element?(
             view,
             "#{alpha}.workspace-card > a#open-#{ctx.workspace.id}[href='/workspaces/#{ctx.workspace.id}'][data-phx-link=patch]"
           )

    assert has_element?(
             view,
             "#{alpha} > details#workspace-menu-#{ctx.workspace.id} > summary" <>
               "[aria-label='Manage Alpha workspace']"
           )

    assert has_element?(view, "#{alpha} > details button#rename-#{ctx.workspace.id}", "Rename")
    refute has_element?(view, "#{alpha} > a details, #{alpha} > a button")

    assert has_element?(
             view,
             "#open-#{ctx.workspace.id}[aria-describedby='workspace-health-#{ctx.workspace.id}']"
           )

    assert has_element?(view, "#{alpha} .workspace-card-problem", ctx.reconnect.email)
    assert has_element?(view, "#{alpha} .workspace-card-problem", "Reconnect required")
    assert has_element?(view, "#{beta} .workspace-card-problem", ctx.limited.email)
    assert has_element?(view, "#{beta} .workspace-card-problem", "Rate limited")
    refute has_element?(view, alpha, ctx.limited.email)
    refute has_element?(view, beta, ctx.reconnect.email)
    refute has_element?(view, "#workspace-list", ctx.healthy.email)
    refute has_element?(view, "#workspace-list", ctx.available.email)
    assert FakeIO.calls() == []

    view |> element("#rename-#{ctx.workspace.id}") |> render_click()
    assert has_element?(view, "#workspace-modal-title", "Rename workspace")
    refute has_element?(view, "#workspace-landing")
    assert socket(view).assigns.selected == nil
  end

  test "account PubSub updates refresh card problems without healthy or cross-workspace leakage",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    status(ctx.reconnect, %{status: :ready, last_error: nil})
    broadcast(ctx.reconnect.id)

    assert has_element?(
             view,
             "#workspace-health-#{ctx.workspace.id}",
             "No reported connection problems"
           )

    refute has_element?(view, "#workspace-health-#{ctx.workspace.id} .workspace-card-problem")
    refute has_element?(view, "#workspace-list", ctx.reconnect.email)
    assert has_element?(view, "#workspace-health-#{ctx.other.id}", ctx.limited.email)

    status(ctx.healthy, %{last_error: :keychain})
    broadcast(ctx.healthy.id)

    for space <- [ctx.workspace, ctx.other] do
      assert has_element?(view, "#workspace-health-#{space.id}", ctx.healthy.email)
      assert has_element?(view, "#workspace-health-#{space.id}", "Check credentials")
    end

    refute has_element?(view, "#workspace-health-#{ctx.workspace.id}", ctx.limited.email)
    status(ctx.available, %{last_error: :provider})
    broadcast(ctx.available.id)
    refute has_element?(view, "#workspace-list", ctx.available.email)
    assert FakeIO.calls() == []
  end

  test "workspace landing has separate integration menus and an explicit add panel", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)

    assert has_element?(view, "#mail-heading", "Integrations")
    assert has_element?(view, "#mail-account-#{ctx.healthy.id}", ctx.healthy.email)
    assert has_element?(view, "#mail-account-#{ctx.reconnect.id}", ctx.reconnect.email)
    refute has_element?(view, "#mail-account-#{ctx.limited.id}")
    refute has_element?(view, "#mail-account-#{ctx.available.id}")
    refute has_element?(view, "#integration-add-panel, #mail-search, #mail-threads")

    assert has_element?(
             view,
             "#mail-account-#{ctx.healthy.id} > details#integration-menu-#{ctx.healthy.id} > summary"
           )

    refute has_element?(view, ".integration-tile-open details, .integration-tile-open button")
    assert has_element?(view, "#detach-#{ctx.healthy.id}", "Remove from workspace")
    refute has_element?(view, "[phx-click='mail:disconnect']")

    reconnect_form = "#mail-connect-#{ctx.reconnect.id}"

    assert has_element?(
             view,
             "#{reconnect_form} input[name=workspace_id][type=hidden][value='#{ctx.workspace.id}']"
           )

    assert has_element?(
             view,
             "#{reconnect_form} input[name=expected_account_id][value='#{ctx.reconnect.id}']"
           )

    view |> element("#add-integration") |> render_click()
    assert has_element?(view, "#integration-add-panel")
    assert has_element?(view, "#mail-available-#{ctx.available.id} #attach-#{ctx.available.id}")
    assert has_element?(view, "#mail-available-#{ctx.limited.id}", ctx.limited.email)
    refute has_element?(view, "#mail-available-#{ctx.healthy.id}")

    assert has_element?(
             view,
             "#mail-connect-new input[name=workspace_id][type=hidden][value='#{ctx.workspace.id}']"
           )

    refute has_element?(view, "#mail-connect-new select[name=workspace_id]")
    view |> element("#close-add-integration") |> render_click()
    refute has_element?(view, "#integration-add-panel")
    assert FakeIO.calls() == []
  end

  test "attachment is explicit and removal is local, never a local disconnect", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)
    render_click(view, "mail:disconnect", %{"id" => ctx.healthy.id})
    assert Mail.get_account!(ctx.healthy.id, actor: @owner).status == :ready
    assert member?(ctx.workspace, ctx.healthy)
    assert member?(ctx.other, ctx.healthy)
    assert FakeIO.calls() == []

    view |> element("#add-integration") |> render_click()
    view |> element("#attach-#{ctx.available.id}") |> render_click()
    assert has_element?(view, "#mail-account-#{ctx.available.id}")
    assert has_element?(view, "#mail-notice", "Account attached to this workspace.")
    refute has_element?(view, "#integration-add-panel")
    assert member?(ctx.workspace, ctx.available)
    refute member?(ctx.other, ctx.available)

    view |> element("#detach-#{ctx.healthy.id}") |> render_click()
    refute has_element?(view, "#mail-account-#{ctx.healthy.id}")

    assert has_element?(
             view,
             "#mail-notice",
             "The account remains available in other workspaces."
           )

    refute member?(ctx.workspace, ctx.healthy)
    assert member?(ctx.other, ctx.healthy)
    assert Mail.get_account!(ctx.healthy.id, actor: @owner).status == :ready

    view |> element("#add-integration") |> render_click()
    assert has_element?(view, "#attach-#{ctx.healthy.id}")
    assert FakeIO.calls() == []
  end

  test "expired available connections require reconnect rather than attachment", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.other)
    view |> element("#add-integration") |> render_click()
    assert has_element?(view, "#mail-available-#{ctx.reconnect.id}")
    refute has_element?(view, "#attach-#{ctx.reconnect.id}")

    assert has_element?(
             view,
             "#mail-connect-#{ctx.reconnect.id} input[name=expected_account_id]" <>
               "[value='#{ctx.reconnect.id}']"
           )

    render_click(view, "mail:attach", %{"id" => ctx.reconnect.id})
    refute member?(ctx.other, ctx.reconnect)
    refute has_element?(view, "#mail-account-#{ctx.reconnect.id}")
    assert FakeIO.calls() == []
  end

  test "global Connections has no workspace or inbox, and forged mail events never read providers",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    mail = socket(view).assigns.mail
    assert mail.scope == :connections
    assert mail.workspace_id == nil
    assert mail.account_id == nil
    assert mail.memberships == []
    assert mail.data_ref == nil
    assert mail.task == nil
    refute mail.loading
    assert socket(view).assigns.selected == nil
    assert socket(view).redirected == nil
    assert has_element?(view, "#directory-heading", "Connections")
    refute has_element?(view, "#workspace-list, #workspace-landing, #mail-search, #mail-threads")

    for connection <- [ctx.healthy, ctx.reconnect, ctx.limited, ctx.available] do
      assert has_element?(view, "#connection-account-#{connection.id}", connection.email)

      assert has_element?(
               view,
               "#connection-account-#{connection.id} button[phx-click='mail:disconnect']" <>
                 "[phx-value-id='#{connection.id}'][data-confirm]",
               "Disconnect everywhere"
             )
    end

    refute has_element?(view, ".mail-account-open, [id^='attach-'], [id^='detach-']")

    for {event, params} <- [
          {"mail:select", %{"id" => ctx.healthy.id}},
          {"mail:search", %{"mail_search" => %{"query" => "synthetic"}}},
          {"mail:refresh", %{}},
          {"mail:thread", %{"id" => "shared-thread"}},
          {"mail:next", %{}},
          {"mail:first", %{}},
          {"mail:back", %{}},
          {"mail:attach", %{"id" => ctx.available.id}},
          {"mail:detach", %{"id" => ctx.healthy.id}}
        ] do
      render_click(view, event, params)
    end

    render_async(view)
    status(ctx.healthy, %{last_error: :provider})
    broadcast(ctx.healthy.id)

    assert has_element?(
             view,
             "#connection-account-#{ctx.healthy.id}",
             "Last check could not reach Gmail."
           )

    assert socket(view).assigns.mail.account_id == nil
    assert socket(view).assigns.mail.task == nil
    assert member?(ctx.workspace, ctx.healthy)
    refute member?(ctx.workspace, ctx.available)
    assert FakeIO.calls() == []
  end

  test "global OAuth forms require an unselected workspace and bind reconnect identity", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)
    open_gmail_connections(view)
    refute has_element?(view, "#mail-connect-new")
    view |> element("#new-gmail-connection") |> render_click()

    assert has_element?(
             view,
             "dialog#gmail-connection-modal[phx-hook=NativeModal][data-cancel-event='mail:close_connection'][data-return-focus='#new-gmail-connection']"
           )

    assert has_element?(view, "#gmail-connection-modal-title", "Add Gmail account")
    assert has_element?(view, "#gmail-connection-modal #mail-connect-new")

    for suffix <- ["new", ctx.reconnect.id] do
      form = "#mail-connect-#{suffix}"
      assert has_element?(view, "#{form}[action='/oauth/google/start'][method=post]")
      assert has_element?(view, "#{form} input[type=hidden][name=_csrf_token]")
      assert has_element?(view, "#{form} select[name=workspace_id][required]:not([disabled])")
      assert has_element?(view, "#{form} select option[value='']", "Choose workspace")
      refute has_element?(view, "#{form} select option[selected]")
      refute has_element?(view, "#{form} input[type=hidden][name=workspace_id]")

      for space <- [ctx.workspace, ctx.other] do
        assert has_element?(view, "#{form} option[value='#{space.id}']", space.name)
      end
    end

    assert has_element?(view, "#mail-connect-new", "Connect and add to")
    refute has_element?(view, "#mail-connect-new input[name=expected_account_id]")
    assert has_element?(view, "#mail-connect-#{ctx.reconnect.id}", "Reconnect and add to")

    assert has_element?(
             view,
             "#mail-connect-#{ctx.reconnect.id} input[type=hidden][name=expected_account_id]" <>
               "[value='#{ctx.reconnect.id}']"
           )

    assert FakeIO.calls() == []
  end

  test "new Gmail modal closes locally, survives metadata updates, and cannot open outside Connections",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_click(view, "mail:new_connection")
    refute socket(view).assigns.mail.connecting
    open_workspace(view, ctx.workspace)
    render_click(view, "mail:new_connection")
    refute socket(view).assigns.mail.connecting

    open_gmail_connections(view)
    view |> element("#new-gmail-connection") |> render_click()
    status(ctx.healthy, %{last_error: :provider})
    broadcast(ctx.healthy.id)
    assert has_element?(view, "#gmail-connection-modal #mail-workspace-new")

    assert has_element?(
             view,
             "#connection-account-#{ctx.healthy.id}",
             "Last check could not reach Gmail"
           )

    view |> element("#gmail-connection-modal button[type=button]") |> render_click()
    refute has_element?(view, "#gmail-connection-modal, #mail-connect-new")
    assert socket(view).assigns.mail.scope == :connections
    assert FakeIO.calls() == []

    view |> element("#new-gmail-connection") |> render_click()
    view |> element("#home-link") |> render_click()
    open_gmail_connections(view)
    refute has_element?(view, "#gmail-connection-modal")
  end

  test "Connections is global and browser history restores a workspace without inbox content",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    view |> element("#show-connections") |> render_click()
    refute has_element?(view, "#back-from-connections")
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#home-overview")
    refute has_element?(view, "#workspace-list")
    assert socket(view).assigns.mail.scope == :workspace
    assert socket(view).assigns.mail.accounts == []

    open_workspace(view, ctx.workspace)
    view |> element("#add-integration") |> render_click()
    view |> element("#show-connections") |> render_click()
    assert_patch(view, "/connections")
    assert socket(view).assigns.selected == nil
    assert has_element?(view, "#connections-overview")
    refute has_element?(view, "#back-from-connections, #connections-subnav")
    render_patch(view, "/workspaces/#{ctx.workspace.id}")
    refute has_element?(view, "#integration-add-panel")
    assert FakeIO.calls() == []

    view |> element("#mail-account-#{ctx.healthy.id} .mail-account-open") |> render_click()
    assert render_async(view) =~ "Synthetic inbox #{ctx.healthy.id}"
    ref = socket(view).assigns.mail.data_ref
    calls = FakeIO.calls()

    view |> element("#show-connections") |> render_click()
    assert_patch(view, "/connections")
    assert has_element?(view, "#connections-overview")
    refute has_element?(view, "#back-from-connections, #connections-subnav")
    assert socket(view).assigns.selected == nil
    assert socket(view).assigns.mail.workspace_id == nil
    assert socket(view).assigns.mail.scope == :connections
    assert ViewData.get(ref) == nil
    refute render(view) =~ "Synthetic inbox"

    view |> element("#open-connection-gmail") |> render_click()
    assert has_element?(view, "#back-to-connections[href='/connections']")
    view |> element("#back-to-connections") |> render_click()
    assert has_element?(view, "#connections-overview")
    assert socket(view).assigns.selected == nil
    render_patch(view, "/workspaces/#{ctx.workspace.id}")
    assert has_element?(view, "#directory-heading", ctx.workspace.name)
    assert has_element?(view, "#mail-heading", "Integrations")
    assert socket(view).assigns.mail.workspace_id == ctx.workspace.id
    assert socket(view).assigns.mail.scope == :workspace
    assert socket(view).assigns.mail.account_id == nil
    refute has_element?(view, "#mail-search, #integration-add-panel")
    assert FakeIO.calls() == calls
    assert socket(view).redirected == nil

    view |> element("#back-to-workspaces") |> render_click()
    assert has_element?(view, "#workspace-list")
    assert socket(view).assigns.selected == nil
    assert socket(view).assigns.mail.workspace_id == nil
    assert socket(view).assigns.mail.subscriptions == []
  end

  test "disconnect everywhere is global, removes all links, and preserves other accounts", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    disconnect(view, ctx.healthy)
    html = render_async(view)

    assert html =~
             "Disconnected everywhere. Local mail cache and credentials removed; Google access revoked."

    refute has_element?(view, "#connection-account-#{ctx.healthy.id}")
    assert has_element?(view, "#connection-account-#{ctx.reconnect.id}")
    assert has_element?(view, "#connection-account-#{ctx.limited.id}")
    assert Mail.get_account!(ctx.healthy.id, actor: @owner).status == :disconnected
    refute member?(ctx.workspace, ctx.healthy)
    refute member?(ctx.other, ctx.healthy)
    assert member?(ctx.workspace, ctx.reconnect)
    assert member?(ctx.other, ctx.limited)

    assert FakeIO.calls() == [
             {:get, ctx.healthy.id},
             {:delete, ctx.healthy.id},
             {:revoke, ctx.healthy.id}
           ]
  end

  test "late view completions cannot populate Connections, another workspace, or a reopened inbox",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)
    FakeIO.block(:inbox)
    view |> element("#mail-account-#{ctx.healthy.id} .mail-account-open") |> render_click()
    assert_receive {:fake_blocked, worker, {:inbox, id, nil}}, 2_000
    assert id == ctx.healthy.id
    old_task = socket(view).assigns.mail.task
    monitor = Process.monitor(worker)

    view |> element("#show-connections") |> render_click()
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
    FakeIO.unblock()
    assert_late_view_ignored(view, old_task)

    render_patch(view, "/workspaces/#{ctx.workspace.id}")
    view |> element("#back-to-workspaces") |> render_click()
    open_workspace(view, ctx.other)
    assert_late_view_ignored(view, old_task)

    view |> element("#back-to-workspaces") |> render_click()
    assert_late_view_ignored(view, old_task)
    open_workspace(view, ctx.workspace)
    view |> element("#mail-account-#{ctx.healthy.id} .mail-account-open") |> render_click()
    assert render_async(view) =~ "Synthetic inbox #{ctx.healthy.id}"
    assert socket(view).assigns.mail.generation != elem(old_task, 4)
    assert_late_view_ignored(view, old_task)
  end

  test "switching providers preserves an in-flight Gmail disconnect without showing Gmail on Gemini",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    FakeIO.block(:revoke)
    disconnect(view, ctx.healthy)
    assert_receive {:fake_blocked, worker, {:revoke, id}}, 2_000
    assert id == ctx.healthy.id
    command = socket(view).assigns.mail.command
    view |> element("#connections-gemini") |> render_click()
    assert socket(view).assigns.mail.command == command
    refute has_element?(view, "#connections-panel")
    send(worker, :release)
    render_async(view)
    assert has_element?(view, "#gemini-connection")
    assert socket(view).assigns.mail.command == nil
    view |> element("#connections-gmail") |> render_click()
    refute has_element?(view, "#connection-account-#{ctx.healthy.id}")
    assert has_element?(view, "#connection-account-#{ctx.available.id}")

    assert has_element?(
             view,
             "#mail-notice",
             "Disconnected everywhere"
           )
  end

  test "a late disconnect result is ignored after leaving and reentering global Connections",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_workspace(view, ctx.workspace)
    open_gmail_connections(view)
    FakeIO.block(:revoke)
    disconnect(view, ctx.healthy)
    assert_receive {:fake_blocked, worker, {:revoke, id}}, 2_000
    assert id == ctx.healthy.id
    {account_id, generation} = socket(view).assigns.mail.command
    name = {:mail, :disconnect, nil, account_id, generation}

    assert has_element?(view, "#new-gmail-connection[disabled]")
    refute has_element?(view, "#gmail-connection-modal, #mail-connect-new")
    render_click(view, "mail:new_connection")
    refute has_element?(view, "#gmail-connection-modal")
    render_patch(view, "/workspaces/#{ctx.workspace.id}")
    assert has_element?(view, "#directory-heading", ctx.workspace.name)
    current = socket(view)
    result = {:ok, {:ok, %{local_removed: true, credentials_removed: true, revoked: true}}}
    assert {:noreply, ^current} = HomeLive.handle_async(name, result, current)

    open_gmail_connections(view)
    assert socket(view).assigns.mail.generation != generation
    assert socket(view).assigns.mail.command == nil
    assert has_element?(view, "#new-gmail-connection:not([disabled])")
    view |> element("#new-gmail-connection") |> render_click()
    assert has_element?(view, "#gmail-connection-modal #mail-connect-new select:not([disabled])")
    view |> element("#gmail-connection-modal button[type=button]") |> render_click()
    send(worker, :release)
    render_async(view)

    assert has_element?(view, "#connections-panel")
    assert socket(view).assigns.mail.scope == :connections
    assert socket(view).assigns.mail.workspace_id == nil
    assert socket(view).assigns.mail.command == nil
    refute has_element?(view, "#mail-notice")
    refute has_element?(view, "#connection-account-#{ctx.healthy.id}")

    assert FakeIO.calls() == [
             {:get, ctx.healthy.id},
             {:delete, ctx.healthy.id},
             {:revoke, ctx.healthy.id}
           ]
  end

  test "local credential checks expose distinct safe observations without changing sync state",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    before = account_state()
    private = "synthetic-private-refresh-token"

    for connection <- [ctx.healthy, ctx.reconnect, ctx.limited, ctx.available] do
      assert has_element?(
               view,
               "#check-credentials-#{connection.id}[phx-click='mail:check_credentials']" <>
                 "[phx-value-id='#{connection.id}']:not([disabled])"
             )
    end

    cases = [
      {{:ok, private}, :accessible, "readable"},
      {{:error, :locked}, :locked, "locked"},
      {{:error, :timeout}, :timeout, "timeout"},
      {{:error, :not_found}, :not_found, "not found"},
      {{:error, :unavailable}, :unavailable, "unavailable"},
      {{:error, :invalid_account}, :invalid_account, "invalid"},
      {{:error, :invalid_value}, :invalid_value, "invalid"}
    ]

    for {response, expected, label} <- cases do
      FakeIO.get_result(ctx.reconnect.id, response)
      check_credentials(view, ctx.reconnect)
      html = render_async(view)
      result = socket(view).assigns.mail.credential_checks[ctx.reconnect.id]
      assert result.generation == ctx.reconnect.generation
      assert result.status == expected
      assert %DateTime{} = result.checked_at
      assert socket(view).assigns.mail.credential_check == nil
      selector = "#credential-check-#{ctx.reconnect.id}[role=status]"
      assert has_element?(view, selector, label)

      assert has_element?(
               view,
               "#{selector} time[datetime='#{DateTime.to_iso8601(result.checked_at)}']"
             )

      assert render(element(view, selector)) =~ ~r/\d{2}:\d{2}/
      refute has_element?(view, "#credential-check-#{ctx.healthy.id}")
      refute html =~ private
      refute inspect(socket(view).assigns) =~ private
      assert account_state() == before
    end

    FakeIO.get_result(ctx.healthy.id, {:ok, private})
    check_credentials(view, ctx.healthy)
    render_async(view)
    assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].status == :accessible
    assert socket(view).assigns.mail.credential_checks[ctx.reconnect.id].status == :invalid_value

    assert Map.keys(socket(view).assigns.mail.credential_checks) |> Enum.sort() ==
             Enum.sort([ctx.healthy.id, ctx.reconnect.id])

    assert FakeIO.calls() ==
             List.duplicate({:get, ctx.reconnect.id}, length(cases)) ++ [{:get, ctx.healthy.id}]
  end

  test "credential diagnostic failures never expose raw vault errors or task exceptions", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    private = "synthetic-private-vault-error"
    before = account_state()
    responses = [{:error, %{private: private}}, {:raise, private}, {:throw, private}]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for response <- responses do
          FakeIO.get_result(ctx.healthy.id, response)
          check_credentials(view, ctx.healthy)
          html = render_async(view)

          assert has_element?(
                   view,
                   "#credential-check-#{ctx.healthy.id}[role=status]",
                   "unavailable"
                 )

          assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].status ==
                   :unavailable

          refute html =~ private
          refute inspect(socket(view).assigns) =~ private
        end
      end)

    refute log =~ private
    assert account_state() == before
    assert FakeIO.calls() == List.duplicate({:get, ctx.healthy.id}, length(responses))
  end

  test "credential checks reject forged scope, provider, missing and disconnected account events",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_click(view, "mail:check_credentials", %{"id" => ctx.healthy.id})
    refute has_element?(view, "[id^='check-credentials-']")
    open_workspace(view, ctx.workspace)
    render_click(view, "mail:check_credentials", %{"id" => ctx.healthy.id})
    assert FakeIO.calls() == []

    status(ctx.available, %{status: :disconnected})
    open_gmail_connections(view)

    for params <- [
          %{"id" => Ash.UUID.generate()},
          %{"id" => "not-an-account"},
          %{"id" => ctx.available.id},
          %{}
        ] do
      render_click(view, "mail:check_credentials", params)
    end

    refute has_element?(view, "#check-credentials-#{ctx.available.id}")
    view |> element("#connections-gemini") |> render_click()
    render_async(view)
    refute has_element?(view, "[id^='check-credentials-']")
    render_click(view, "mail:check_credentials", %{"id" => ctx.healthy.id})
    assert socket(view).assigns.mail.credential_check == nil
    assert socket(view).assigns.mail.credential_checks == %{}
    assert FakeIO.calls() == []
    assert Mail.get_account!(ctx.healthy.id, actor: @owner).status == :ready
  end

  test "one active check disables every account and fences mismatched requests and task errors",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    FakeIO.block(:get)
    check_credentials(view, ctx.healthy)
    assert_receive {:fake_blocked, worker, {:get, id}}, 2_000
    assert id == ctx.healthy.id
    {account_id, generation, request_id} = active = socket(view).assigns.mail.credential_check
    assert generation == ctx.healthy.generation
    name = {:mail, :credential_check, account_id, generation, request_id}

    for connection <- [ctx.healthy, ctx.reconnect, ctx.limited, ctx.available] do
      assert has_element?(view, "#check-credentials-#{connection.id}[disabled]")
    end

    assert has_element?(view, "#credential-check-#{ctx.healthy.id}[role=status]", "Checking")
    render_click(view, "mail:check_credentials", %{"id" => ctx.limited.id})
    render_click(view, "mail:check_credentials", %{"id" => ctx.healthy.id})
    assert socket(view).assigns.mail.credential_check == active
    assert FakeIO.calls() == [{:get, ctx.healthy.id}]

    for stale_name <- [
          {:mail, :credential_check, ctx.limited.id, generation, request_id},
          {:mail, :credential_check, account_id, Ash.UUID.generate(), request_id},
          {:mail, :credential_check, account_id, generation, request_id + 1}
        ] do
      assert_credential_completion_ignored(view, stale_name)
    end

    current = socket(view)
    private = "synthetic-private-task-error"

    for failure <- [
          {:exit, private},
          {:ok, {:error, %{private: private}}},
          {:ok, {:ok, %{status: {:unknown, private}}}}
        ] do
      assert {:noreply, failed} = HomeLive.handle_async(name, failure, current)
      assert failed.assigns.mail.credential_check == nil
      assert failed.assigns.mail.credential_checks[account_id].status == :unavailable
      refute inspect(failed.assigns) =~ private
    end

    send(worker, :release)
    render_async(view)
    assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].status == :accessible
    assert socket(view).assigns.mail.credential_check == nil
    assert has_element?(view, "#check-credentials-#{ctx.limited.id}:not([disabled])")
    assert FakeIO.calls() == [{:get, ctx.healthy.id}]
  end

  test "leaving and reentering Connections rejects a pending completion even during a new check",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    FakeIO.block(:get)
    check_credentials(view, ctx.healthy)
    assert_receive {:fake_blocked, worker, {:get, id}}, 2_000
    assert id == ctx.healthy.id
    {account_id, generation, request_id} = socket(view).assigns.mail.credential_check
    old_name = {:mail, :credential_check, account_id, generation, request_id}
    monitor = Process.monitor(worker)
    view |> element("#home-link") |> render_click()
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
    assert_credential_completion_ignored(view, old_name)

    open_gmail_connections(view)
    assert socket(view).assigns.mail.credential_checks == %{}
    assert socket(view).assigns.mail.credential_check == nil
    assert_credential_completion_ignored(view, old_name)
    check_credentials(view, ctx.healthy)
    assert_receive {:fake_blocked, next_worker, {:get, ^id}}, 2_000

    assert {^account_id, ^generation, next_request_id} =
             socket(view).assigns.mail.credential_check

    refute next_request_id == request_id
    assert_credential_completion_ignored(view, old_name)
    send(next_worker, :release)
    render_async(view)
    assert socket(view).assigns.mail.credential_checks[ctx.healthy.id].status == :accessible
    assert FakeIO.calls() == [{:get, id}, {:get, id}]
  end

  test "reconnect during a pending check discards the old generation result", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    FakeIO.block(:get)
    check_credentials(view, ctx.healthy)
    assert_receive {:fake_blocked, worker, {:get, id}}, 2_000
    assert id == ctx.healthy.id
    {account_id, generation, request_id} = socket(view).assigns.mail.credential_check
    old_name = {:mail, :credential_check, account_id, generation, request_id}
    reconnected = reconnect_generation(ctx.healthy)
    broadcast(id)
    render(view)
    current = socket(view)

    assert {:noreply, completed} =
             HomeLive.handle_async(old_name, {:ok, {:ok, %{status: :accessible}}}, current)

    refute Map.has_key?(completed.assigns.mail.credential_checks, id)
    send(worker, :release)
    render_async(view)
    refute has_element?(view, "#credential-check-#{id}")
    refute Map.has_key?(socket(view).assigns.mail.credential_checks, id)
    assert socket(view).assigns.mail.credential_check == nil

    FakeIO.unblock()
    check_credentials(view, reconnected)
    render_async(view)
    assert socket(view).assigns.mail.credential_checks[id].generation == reconnected.generation
    assert socket(view).assigns.mail.credential_checks[id].status == :accessible
    assert FakeIO.calls() == [{:get, id}, {:get, id}]
  end

  test "metadata changes invalidate only the changed account's credential observation", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    open_gmail_connections(view)
    check_credentials(view, ctx.healthy)
    render_async(view)
    FakeIO.get_result(ctx.limited.id, {:error, :locked})
    check_credentials(view, ctx.limited)
    render_async(view)
    limited_check = socket(view).assigns.mail.credential_checks[ctx.limited.id]
    reconnect_generation(ctx.healthy)
    broadcast(ctx.healthy.id)
    refute has_element?(view, "#credential-check-#{ctx.healthy.id}")
    assert socket(view).assigns.mail.credential_checks[ctx.limited.id] == limited_check
    assert has_element?(view, "#credential-check-#{ctx.limited.id}", "locked")

    status(ctx.limited, %{status: :disconnected})
    broadcast(ctx.limited.id)
    refute has_element?(view, "#credential-check-#{ctx.limited.id}")
    assert socket(view).assigns.mail.credential_checks == %{}
    assert FakeIO.calls() == [{:get, ctx.healthy.id}, {:get, ctx.limited.id}]
  end

  defp open_gmail_connections(view) do
    view |> element("#show-connections") |> render_click()
    view |> element("#open-connection-gmail") |> render_click()
  end

  defp check_credentials(view, account) do
    view |> element("#check-credentials-#{account.id}") |> render_click()
  end

  defp assert_credential_completion_ignored(view, name) do
    current = socket(view)
    result = {:ok, {:ok, %{status: :accessible}}}
    assert {:noreply, ^current} = HomeLive.handle_async(name, result, current)
  end

  defp account_state do
    Enum.map(Mail.list_accounts!(actor: @owner), fn account ->
      Map.take(account, Enum.map(Info.attributes(Account), & &1.name))
    end)
  end

  defp reconnect_generation(account) do
    Mail.save_connection!(
      %{
        id: account.id,
        subject: account.subject,
        email: account.email,
        generation: Ash.UUID.generate()
      },
      actor: @owner
    )
  end

  defp fake_gemini_vault do
    start_supervised!(GeminiVault)
    previous = Application.fetch_env(:lovelace, :gemini_vault)
    Application.put_env(:lovelace, :gemini_vault, GeminiVault)
    on_exit(fn -> restore(:gemini_vault, previous) end)
  end

  defp assert_late_view_ignored(view, name) do
    current = socket(view)
    ref = ViewData.put(%{"threads" => [%{"id" => "late", "subject" => "Late foreign payload"}]})

    result =
      {:ok,
       {:ok,
        %{
          data_ref: ref,
          fetched_at: ~U[2026-11-01 12:00:00Z],
          cached: false,
          stale: false,
          error: nil
        }}}

    # Replay the captured task name through HomeLive's real callback dispatcher.
    # LiveView normally cancels the worker before it can deliver this completion.
    assert {:noreply, ^current} = HomeLive.handle_async(name, result, current)
    refute render(view) =~ "Late foreign payload"
    ViewData.clear()
  end

  defp open_workspace(view, workspace) do
    view |> element("#show-workspaces") |> render_click()
    view |> element("#open-#{workspace.id}") |> render_click()
  end

  defp disconnect(view, connection) do
    view
    |> element("#connection-account-#{connection.id} button[phx-click='mail:disconnect']")
    |> render_click()
  end

  defp socket(view), do: :sys.get_state(view.pid).socket

  defp member?(workspace, connection) do
    workspace.id
    |> Mail.workspace_accounts!(actor: @owner)
    |> Enum.any?(&(&1.account_id == connection.id))
  end

  defp account(name) do
    Mail.save_connection!(
      %{
        id: Ash.UUID.generate(),
        subject: "synthetic-#{name}",
        email: "#{name}@example.test",
        generation: Ash.UUID.generate()
      },
      actor: @owner
    )
  end

  defp status(connection, fields) do
    Mail.update_account!(
      connection,
      Map.put(fields, :expected_generation, connection.generation),
      actor: @owner
    )
  end

  defp broadcast(id),
    do: Phoenix.PubSub.broadcast(Lovelace.PubSub, "mail:#{id}", {:mail_changed, id})

  defp restore(key, {:ok, value}), do: Application.put_env(:lovelace, key, value)
  defp restore(key, :error), do: Application.delete_env(:lovelace, key)
end
