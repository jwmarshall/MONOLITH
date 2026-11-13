defmodule MonolithWeb.NavigationLiveTest do
  use MonolithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Monolith.{Mail, Workspaces}
  alias Monolith.TestSupport.BackgroundWork
  alias MonolithWeb.HomeNavigation

  @owner %{role: :local_owner}

  defmodule FakeMail do
    @moduledoc false
    def get(id), do: {:ok, id}
    @spec refresh(binary()) :: {:ok, Monolith.Google.OAuthProvider.tokens()}
    def refresh(id), do: {:ok, %{access_token: id, expires_in: 3600}}

    @spec inbox(binary(), Monolith.Mail.Provider.page_token()) ::
            {:ok, Monolith.Mail.Provider.page()}
    def inbox(id, page), do: result(id, nil, page)

    @spec search(binary(), binary(), Monolith.Mail.Provider.page_token()) ::
            {:ok, Monolith.Mail.Provider.page()}
    def search(id, query, page), do: result(id, query, page)

    @spec thread(binary(), binary()) :: {:ok, Monolith.Mail.Provider.thread()}
    def thread(id, thread),
      do:
        {:ok,
         %{
           id: thread,
           messages: [
             %{
               id: thread,
               subject: id,
               from: "sender@example.test",
               to: "owner@example.test",
               date: "Today",
               text: "Synthetic reader",
               attachments: []
             }
           ]
         }}

    defp result(id, query, page) do
      {:ok,
       %{
         threads: [
           %{
             id: "deep-thread",
             subject: Enum.join([id, query || "inbox", page || "first"], " "),
             from: "sender@example.test",
             snippet: "Synthetic reader",
             date: "Today",
             unread: false
           }
         ],
         next_page_token: "second"
       }}
    end
  end

  setup %{conn: conn} do
    previous =
      Map.new([:gmail_provider, :gmail_vault], &{&1, Application.fetch_env(:monolith, &1)})

    Application.put_env(:monolith, :gmail_provider, FakeMail)
    Application.put_env(:monolith, :gmail_vault, FakeMail)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:monolith, key, value)
        {key, :error} -> Application.delete_env(:monolith, key)
      end)
    end)

    workspace = Workspaces.create_workspace!("Navigation workspace", actor: @owner)
    other = Workspaces.create_workspace!("Other navigation workspace", actor: @owner)

    account =
      Mail.save_connection!(
        %{
          id: Ash.UUID.generate(),
          email: "navigation@example.test",
          subject: "navigation",
          generation: Ash.UUID.generate()
        },
        actor: @owner
      )

    unattached =
      Mail.save_connection!(
        %{
          id: Ash.UUID.generate(),
          email: "unattached@example.test",
          subject: "unattached-navigation",
          generation: Ash.UUID.generate()
        },
        actor: @owner
      )

    Mail.link(workspace.id, account.id, actor: @owner)

    %{
      conn: authenticate_owner(conn),
      workspace: workspace,
      other: other,
      account: account,
      unattached: unattached
    }
  end

  test "main destinations and provider selection use real patch links", ctx do
    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "a#show-workspaces[href='/workspaces'][data-phx-link=patch]")
    view |> element("#show-workspaces") |> render_click()
    assert_patch(view, "/workspaces")

    assert has_element?(
             view,
             "a#open-#{ctx.workspace.id}[href='/workspaces/#{ctx.workspace.id}']"
           )

    view |> element("#open-#{ctx.workspace.id}") |> render_click()
    assert_patch(view, "/workspaces/#{ctx.workspace.id}")
    view |> element("#show-connections") |> render_click()
    assert_patch(view, "/connections")
    assert has_element?(view, "#connections-overview")
    refute has_element?(view, "#connections-subnav, #back-from-connections")
    assert state(view).selected == nil
    view |> element("#open-connection-calendar") |> render_click()
    assert_patch(view, "/connections/calendar")
    assert has_element?(view, "#calendar-connections")
    assert has_element?(view, "#back-to-connections[href='/connections']")
    render_patch(view, "/workspaces/#{ctx.workspace.id}")
    assert has_element?(view, "#workspace-landing #mail-accounts")
    refute has_element?(view, "#calendar-connections")
    render_patch(view, "/connections/calendar")
    refute has_element?(view, "#back-from-connections")
  end

  test "Settings is an exclusive patch destination with idle and startup controls", ctx do
    {:ok, view, _} = live(ctx.conn, "/")

    view |> element("#show-settings") |> render_click()
    assert_patch(view, "/settings")
    assert_push_event(view, "workspace:focus-heading", %{})
    assert has_element?(view, "#show-settings[aria-current=page]")
    assert has_element?(view, "#directory-heading", "Settings")

    assert has_element?(
             view,
             "#settings-panel #idle-preference input[name=minutes][type=number][min='1'][max='60'][required]"
           )

    assert has_element?(view, "#idle-preference label[for=idle-minutes]")
    assert has_element?(view, "#idle-preference button[type=submit]", "Save preference")

    assert has_element?(
             view,
             "#startup-preference input[type=checkbox][name=enabled]:not([checked])"
           )

    assert has_element?(view, "#startup-preference button[type=submit]", "Save startup choice")

    refute has_element?(
             view,
             "#home-overview, #workspace-list, #workspace-landing, #home-inbox, " <>
               "#connections-overview, #scenes-panel, #new-workspace, #show-workspaces[aria-current=page]"
           )

    for {path, selector} <- [
          {"/", "#home-overview"},
          {"/workspaces", "#workspace-list"},
          {"/workspaces/#{ctx.workspace.id}", "#workspace-landing"},
          {"/connections", "#connections-overview"},
          {"/scenes", "#scenes-panel"}
        ] do
      render_patch(view, path)
      assert has_element?(view, selector)
      refute has_element?(view, "#settings-panel")
      render_patch(view, "/settings")
      assert has_element?(view, "#settings-panel")
      refute has_element?(view, selector)
      assert state(view).navigation_path == "/settings"
    end
  end

  test "startup opt-in persists across reload and can be switched off again", ctx do
    {:ok, view, _} = live(ctx.conn, "/settings")
    assert has_element?(view, "#startup-preference input[type=checkbox]:not([checked])")

    view |> form("#startup-preference", %{enabled: "true"}) |> render_submit()
    assert has_element?(view, "#startup-preference input[type=checkbox][checked]")
    assert has_element?(view, "#startup-status[role=status]", "No generation was started")

    {:ok, reloaded, _} = live(ctx.conn, "/settings")
    assert has_element?(reloaded, "#startup-preference input[type=checkbox][checked]")
    reloaded |> form("#startup-preference", %{enabled: "false"}) |> render_submit()
    assert has_element?(reloaded, "#startup-preference input[type=checkbox]:not([checked])")

    {:ok, disabled, _} = live(ctx.conn, "/settings")
    assert has_element?(disabled, "#startup-preference input[type=checkbox]:not([checked])")
  end

  test "Settings deep entry and reload discard unrelated context without restoring mail", ctx do
    {:ok, view, _} = live(ctx.conn, HomeNavigation.account_path(ctx.account.id))
    BackgroundWork.complete(view)
    old = state(view).mail
    render_patch(view, "/settings?workspace=#{ctx.workspace.id}&page=bad&q=ignored")
    assert_patch(view, "/settings")
    assert has_element?(view, "#settings-panel")
    assert state(view).mail.account_id == nil
    assert state(view).mail.generation != old.generation
    assert state(view).directory_subscriptions == []
    send(view.pid, {:mail_changed, ctx.account.id})
    render(view)
    assert state(view).navigation_path == "/settings"
    refute has_element?(view, "#mail-account-view, #mail-conversation")

    {:ok, reloaded, _} = live(ctx.conn, "/settings")
    assert has_element?(reloaded, "#settings-panel")
    assert has_element?(reloaded, "#show-settings[aria-current=page]")
    refute has_element?(reloaded, "#workspace-list, #home-overview, #home-inbox")
  end

  test "Connections is a global overview on direct entry and reload", ctx do
    for path <- [
          "/connections",
          "/connections?workspace=#{ctx.workspace.id}",
          "/connections?workspace[old]=ignored"
        ] do
      {:ok, view, _} = live(ctx.conn, path)
      assert state(view).navigation_path == "/connections"
      assert state(view).selected == nil
      assert has_element?(view, "#connections-overview a[href='/connections/gmail']")
      assert has_element?(view, "#connections-overview a[href='/connections/calendar']")
      assert has_element?(view, "#connections-overview a[href='/connections/gemini']")

      refute has_element?(
               view,
               "#connections-panel, #gemini-connection, #calendar-connections, #connections-subnav, #back-from-connections"
             )

      assert state(view).gemini_status == :unknown
    end
  end

  test "obsolete provider queries are removed without restoring workspace context", ctx do
    for provider <- ["gmail", "calendar", "gemini"] do
      {:ok, view, _} =
        live(ctx.conn, "/connections/#{provider}?workspace=missing&q=obsolete&page=2")

      BackgroundWork.complete(view)
      assert state(view).navigation_path == "/connections/#{provider}"
      assert state(view).selected == nil
      assert has_element?(view, "#back-to-connections[href='/connections']")
      view |> element("#show-connections") |> render_click()
      assert_patch(view, "/connections")
      assert has_element?(view, "#connections-overview")
      render_patch(view, "/connections/#{provider}")
      assert has_element?(view, "#connections-#{provider}[aria-current=page]")
    end
  end

  test "legacy bookmarks resolve to canonical paths", ctx do
    for {legacy, canonical, selector} <- [
          {"/?connections=gemini", "/connections/gemini", "#gemini-connection"},
          {"/?workspace=#{ctx.workspace.id}", "/workspaces/#{ctx.workspace.id}",
           "#workspace-landing"},
          {"/?gmail=failed&stage=consent&reason=denied", "/connections/gmail",
           "#connections-panel"},
          {"/?calendar=connected&workspace=#{ctx.workspace.id}", "/connections/calendar",
           "#calendar-connections"}
        ] do
      {:ok, view, _} = live(ctx.conn, legacy)
      BackgroundWork.complete(view)
      assert state(view).navigation_path == canonical
      assert has_element?(view, selector)
    end
  end

  test "workspace and integration setup restore on direct entry", ctx do
    path = "/workspaces/#{ctx.workspace.id}/integrations"
    {:ok, view, _} = live(ctx.conn, path)
    assert has_element?(view, "#integration-add-panel")
    view |> element("#close-add-integration") |> render_click()
    assert_patch(view, "/workspaces/#{ctx.workspace.id}")
    refute has_element?(view, "#integration-add-panel")
    render_patch(view, path)
    assert has_element?(view, "#integration-add-panel")
  end

  test "search, pagination, and conversation URL restore the exact account context", ctx do
    base = "/workspaces/#{ctx.workspace.id}/accounts/#{ctx.account.id}/mail"
    query = "from:sender@example.test & unread"
    results = base <> "?" <> URI.encode_query(q: query, page_token: "second")
    thread = base <> "/threads/deep-thread?" <> URI.encode_query(q: query, page_token: "second")
    {:ok, view, _} = live(ctx.conn, thread)
    BackgroundWork.complete(view)
    assert has_element?(view, "#mail-conversation", "Synthetic reader")
    assert has_element?(view, "#mail-back[href='#{results}']")
    refute has_element?(view, "#mail-threads")
    view |> element("#mail-back") |> render_click()
    assert_patch(view, results)
    BackgroundWork.complete(view)
    assert has_element?(view, "#mail-search input[value='#{query}']")
    assert has_element?(view, "#mail-thread-deep-thread", "#{query} second")
    key = state(view).mail.list_key
    render_patch(view, thread)
    BackgroundWork.complete(view)
    assert state(view).mail.list_key == key
    render_patch(view, results)
    BackgroundWork.complete(view)
    assert state(view).mail.list_key == key
    assert has_element?(view, "#mail-thread-deep-thread", "#{query} second")
    {:ok, reloaded, _} = live(ctx.conn, results)
    BackgroundWork.complete(reloaded)
    assert has_element?(reloaded, "#mail-thread-deep-thread", "#{query} second")
  end

  test "submitted search writes a restorable URL, not each keystroke", ctx do
    base = HomeNavigation.account_path(ctx.account.id)
    {:ok, view, _} = live(ctx.conn, base)
    BackgroundWork.complete(view)
    view |> form("#mail-search", mail_search: %{query: "everywhere"}) |> render_submit()
    assert_patch(view, base <> "?q=everywhere")
    BackgroundWork.complete(view)
    assert has_element?(view, "#mail-thread-deep-thread", "everywhere first")
    view |> element("#mail-thread-deep-thread") |> render_click()
    assert_patch(view, base <> "/threads/deep-thread?q=everywhere")
  end

  test "oversized search retains results and navigation without starting another read", ctx do
    path = HomeNavigation.account_path(ctx.account.id) <> "?q=retained&page_token=second"
    {:ok, view, _} = live(ctx.conn, path)
    BackgroundWork.complete(view)
    previous = state(view).mail
    assert has_element?(view, "#mail-thread-deep-thread", "retained second")

    render_submit(view, "mail:search", %{
      "mail_search" => %{"query" => String.duplicate("a", 1025)}
    })

    assert has_element?(view, "#flash-error[role=alert]")
    assert has_element?(view, "#mail-thread-deep-thread", "retained second")
    assert state(view).navigation_path == path
    assert state(view).mail.task == previous.task
    assert state(view).mail.generation == previous.generation
    assert state(view).mail.query == "retained"
    refute_patched(view)
  end

  test "direct account URLs support unattached accounts without creating membership", ctx do
    {:ok, view, _} = live(ctx.conn, HomeNavigation.account_path(ctx.unattached.id))
    BackgroundWork.complete(view)
    assert has_element?(view, "#mail-heading", ctx.unattached.email)
    assert {:ok, []} = Mail.workspace_accounts(ctx.other.id, actor: @owner)
    assert state(view).mail.workspace_id == nil
    assert state(view).mail.scope == :home
  end

  test "workspace mail URLs cannot address an unattached account", ctx do
    path = "/workspaces/#{ctx.other.id}/accounts/#{ctx.account.id}/mail/threads/deep-thread"
    {:ok, view, _} = live(ctx.conn, path)
    assert state(view).navigation_path == "/workspaces"
    refute has_element?(view, "#mail-account-view, #mail-conversation")
    assert has_element?(view, "#flash-error", "unavailable")
    assert state(view).mail.account_id == nil
  end

  test "history transitions fence delayed results and clear the previous account", ctx do
    {:ok, view, _} = live(ctx.conn, HomeNavigation.account_path(ctx.account.id))
    BackgroundWork.complete(view)
    old = state(view).mail
    render_patch(view, HomeNavigation.account_path(ctx.unattached.id))
    BackgroundWork.complete(view)
    send(view.pid, {:mail_changed, ctx.account.id})
    render(view)
    assert state(view).mail.account_id == ctx.unattached.id
    assert state(view).mail.generation != old.generation
    refute render(view) =~ ctx.account.email
    render_patch(view, "/workspaces")
    assert state(view).mail.account_id == nil
    assert state(view).mail.data_ref == nil
  end

  test "account disappearance replaces the invalid URL and leaves usable navigation", ctx do
    {:ok, view, _} = live(ctx.conn, HomeNavigation.account_path(ctx.account.id))
    BackgroundWork.complete(view)

    Mail.update_account!(
      ctx.account,
      %{status: :disconnected, expected_generation: ctx.account.generation},
      actor: @owner
    )

    send(view.pid, {:mail_changed, ctx.account.id})
    render(view)
    assert_patch(view, "/workspaces")
    assert has_element?(view, "#workspace-list")
    refute has_element?(view, "#home-inbox, #mail-account-view")
    assert state(view).mail.scope == :workspace
    view |> element("#home-link") |> render_click()
    assert_patch(view, "/")
    view |> element("#show-workspaces") |> render_click()
    assert_patch(view, "/workspaces")
    assert has_element?(view, "#workspace-list")
  end

  test "invalid and missing destinations recover without leaving stale content", ctx do
    for path <- [
          "/workspaces/not-a-uuid",
          "/workspaces/#{Ecto.UUID.generate()}",
          "/connections/unknown",
          "/accounts/#{ctx.account.id}/mail/threads/bad%20thread",
          "/scenes?page=0",
          "/accounts/#{ctx.account.id}/mail?q[bad]=value",
          "/accounts/#{ctx.account.id}/mail?q=" <> String.duplicate("a", 1025)
        ] do
      {:ok, view, _} = live(ctx.conn, path)
      assert state(view).navigation_path == "/workspaces"
      assert has_element?(view, "#workspace-list")
      refute has_element?(view, "#mail-account-view")
    end
  end

  test "Scenes page and Connections provider survive direct entry", ctx do
    {:ok, view, _} = live(ctx.conn, "/connections/calendar")
    assert has_element?(view, "#connections-calendar[aria-current=page]")
    assert has_element?(view, "#calendar-connections")
    render_patch(view, "/scenes?page=2")
    BackgroundWork.complete(view)
    assert state(view).scene_page == 2
    assert has_element?(view, "#scenes-panel")
    render_patch(view, "/connections/calendar")
    assert has_element?(view, "#calendar-connections")
  end

  test "destination projection stays exclusive through history while scenery and subscriptions survive",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/")
    background = state(view).background.url

    for {path, action, selector} <- [
          {"/workspaces", :workspaces, "#workspace-list"},
          {"/workspaces/#{ctx.workspace.id}", :workspace, "#workspace-landing"},
          {"/workspaces/#{ctx.workspace.id}/integrations", :integration_add,
           "#integration-add-panel"},
          {"/connections", :connections, "#connections-overview"},
          {"/settings", :settings, "#settings-panel"},
          {"/", :index, "#home-overview"},
          {"/workspaces", :workspaces, "#workspace-list"}
        ] do
      render_patch(view, path)
      assigns = state(view)
      assert assigns.destination.action == action
      assert HomeNavigation.current(%{assigns: assigns}) == path
      assert assigns.navigation_path == path
      assert assigns.background.url == background
      assert has_element?(view, selector)

      assert Enum.count(
               [assigns.home, assigns.settings, assigns.connections, assigns.scenes],
               & &1
             ) <= 1

      unless action in [:index, :workspaces] do
        assert assigns.directory_subscriptions == []
      end
    end
  end

  test "A to B to A rejects an earlier admission even when the account destination matches again",
       ctx do
    Oban.Testing.with_testing_mode(:manual, fn ->
      path = HomeNavigation.account_path(ctx.account.id)
      {:ok, view, _} = live(ctx.conn, path)
      earlier = state(view).mail
      assert is_binary(earlier.task)

      render_patch(view, HomeNavigation.account_path(ctx.unattached.id))
      render_patch(view, path)
      current = state(view).mail
      assert is_binary(current.task)
      refute current.task == earlier.task
      refute current.generation == earlier.generation

      send(view.pid, {:mail_operation, earlier.task})
      send(view.pid, {:mail_observe, earlier.task, 1})
      send(view.pid, {:mail_changed, ctx.unattached.id})
      render(view)

      assert state(view).mail.task == current.task
      assert state(view).mail.generation == current.generation
      assert state(view).destination.account_id == ctx.account.id
      assert state(view).navigation_path == path
      assert has_element?(view, "#mail-heading", ctx.account.email)
      refute has_element?(view, "#mail-heading", ctx.unattached.email)
      refute has_element?(view, "#workspace-list, #connections-overview, #settings-panel")
    end)
  end

  defp state(view), do: :sys.get_state(view.pid).socket.assigns
end
