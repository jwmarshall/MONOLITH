defmodule LovelaceWeb.HomeOverviewLiveTest do
  use LovelaceWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Lovelace.Mail
  alias Lovelace.Mail.Operations
  alias Lovelace.Workspaces

  @owner %{role: :local_owner}

  defmodule Vault do
    @moduledoc false
    def get(id), do: {:ok, "synthetic-" <> id}
  end

  defmodule Provider do
    @moduledoc false
    def refresh(token), do: {:ok, %{access_token: token}}

    def inbox(token, _page) do
      send(Application.fetch_env!(:lovelace, :home_test_owner), {:home_fetch, token})
      {:ok, %{threads: [], next_page_token: nil}}
    end
  end

  setup %{conn: conn} do
    for {key, value} <- [gmail_provider: Provider, gmail_vault: Vault, home_test_owner: self()] do
      previous = Application.fetch_env(:lovelace, key)
      Application.put_env(:lovelace, key, value)

      on_exit(fn ->
        case previous do
          {:ok, previous} -> Application.put_env(:lovelace, key, previous)
          :error -> Application.delete_env(:lovelace, key)
        end
      end)
    end

    {:ok, conn: authenticate_owner(conn)}
  end

  test "Home defaults to one metadata-only row per connection, with workspace labels", %{
    conn: conn
  } do
    first = account("first", 12)
    second = account("second", 0)
    orphan = account("orphan", nil)
    shared = Workspaces.create_workspace!("Shared", actor: @owner)
    personal = Workspaces.initialize_personal!(actor: @owner)

    for workspace <- [shared, personal] do
      Mail.attach_account!(%{workspace_id: workspace.id, account_id: first.id}, actor: @owner)
    end

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#center-nav #home-link[aria-label='Home'][aria-current=page]",
             "Home"
           )

    assert has_element?(view, "#daily-heading[phx-hook=DailyOrientation][phx-update=ignore]")
    assert has_element?(view, ".workspace-directory-home #home-readouts > #home-overview")
    assert has_element?(view, "#home-readouts > #calendar-agenda")

    assert has_element?(
             view,
             "#home-account-#{first.id} .home-account-workspaces",
             "Personal · Shared"
           )

    assert has_element?(view, "#home-count-#{first.id}", "12")
    assert has_element?(view, "#home-count-#{first.id} .home-unread-label", "unread")
    refute has_element?(view, "#home-count-#{first.id}", "inbox conversations")
    refute has_element?(view, "#daily-heading p")
    refute has_element?(view, ".home-section-heading p, .home-footnote")
    assert has_element?(view, "#home-count-#{second.id}", "0")
    assert has_element?(view, "#home-count-#{orphan.id} .home-unread-number", "—")
    assert has_element?(view, "#home-count-#{orphan.id} .sr-only", "total unavailable")
    refute has_element?(view, "#home-health-#{orphan.id}", "Not checked yet")
    refute has_element?(view, "#home-overview", "Last checked")
    assert has_element?(view, "#home-freshness-#{first.id}[data-warnings-only=true]")
    assert has_element?(view, "#home-account-#{orphan.id}", "Not in a workspace")

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".home-account")
           |> Enum.count() == 3

    refute has_element?(view, "#workspace-list, #mail-search, #mail-threads")
    refute_receive {:home_fetch, _}
  end

  test "Home opens an unattached account inbox without attaching it, and center nav returns Home",
       %{conn: conn} do
    account = account("unattached", 7)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#open-home-account-#{account.id}") |> render_click()
    render_async(view)
    assert_receive {:home_fetch, token}
    assert token == "synthetic-" <> account.id
    assert has_element?(view, "#home-inbox .mail-inbox-heading #mail-heading", account.email)
    assert has_element?(view, ".mail-inbox-heading #mail-search input[aria-label='Search Gmail']")
    assert has_element?(view, "#mail-search button[type=submit]", "Search")
    refute has_element?(view, "#mail-panel button", "Home")
    refute has_element?(view, "#mail-panel button", "All accounts")
    refute has_element?(view, "#mail-search .label")
    refute render(view) =~ "Separate accounts. Nothing sent, changed, or marked as read."
    refute render(view) =~ "Search this entire Gmail account"
    assert has_element?(view, "#mail-threads", "Your inbox is empty")
    assert Mail.list_workspace_accounts!(actor: @owner) == []

    view |> element("#home-link") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    assert has_element?(view, "#home-overview")
    refute has_element?(view, "#mail-account-view")
    refute_receive {:home_fetch, _}
  end

  test "count updates stay account-scoped and retain visible stale/error context", %{conn: conn} do
    first = account("first", 8)
    second = account("second", 19)
    {:ok, view, _html} = live(conn, ~p"/")

    Mail.update_account!(
      first,
      %{expected_generation: first.generation, inbox_unread_error: :rate_limited},
      actor: @owner
    )

    Operations.broadcast(first.id)
    assert has_element?(view, "#home-count-#{first.id}", "8")
    assert has_element?(view, "#home-health-#{first.id}", "Gmail rate limit")
    assert has_element?(view, "#home-freshness-#{first.id}[data-failed=true]")
    assert has_element?(view, "#home-count-#{second.id}", "19")
    refute_receive {:home_fetch, _}
  end

  test "unrelated account updates never request the selected Home inbox", %{conn: conn} do
    first = account("first", 2)
    second = account("second", 3)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#open-home-account-#{first.id}") |> render_click()
    render_async(view)
    assert_receive {:home_fetch, _}

    Operations.broadcast(second.id)
    assert has_element?(view, "#mail-heading", first.email)
    refute_receive {:home_fetch, _}

    view |> element("#home-link") |> render_click()
    view |> element("#open-home-account-#{second.id}") |> render_click()
    render_async(view)
    assert_receive {:home_fetch, token}
    assert token == "synthetic-" <> second.id
    assert has_element?(view, "#mail-heading", second.email)
  end

  test "reconnect and removed accounts remain truthful and forged IDs do not open mail", %{
    conn: conn
  } do
    account = account("reconnect", nil)

    Mail.update_account!(
      account,
      %{expected_generation: account.generation, status: :reconnect, last_error: :reconnect},
      actor: @owner
    )

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-health-#{account.id}", "Reconnect required")
    assert has_element?(view, "#home-count-#{account.id} .sr-only", "total unavailable")
    assert has_element?(view, "#home-health-#{account.id} .home-recovery", "Connections")

    render_click(view, "open_home_account", %{"id" => Ash.UUID.generate()})
    refute has_element?(view, "#mail-account-view")
    assert has_element?(view, "#flash-error", "unavailable")

    view |> element("#open-home-account-#{account.id}") |> render_click()
    render_async(view)
    assert has_element?(view, "#home-inbox button", "Reconnect in Connections")
    refute_receive {:home_fetch, _}

    view |> element("#home-link") |> render_click()
    current = Mail.get_account!(account.id, actor: @owner)

    Mail.update_account!(
      current,
      %{expected_generation: current.generation, status: :disconnected},
      actor: @owner
    )

    Operations.broadcast(account.id)
    assert has_element?(view, "#home-empty")
    refute has_element?(view, "#home-account-#{account.id}")
  end

  test "empty Home is concise and Connections has no redundant Home button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-empty p", "No Gmail accounts connected.")
    assert has_element?(view, "#home-empty button", "Connect Gmail")
    refute has_element?(view, "#daily-heading p, .home-section-heading p, .home-footnote")
    assert has_element?(view, "#calendar-agenda .calendar-empty", "Calendar not enabled.")
    assert has_element?(view, "#calendar-agenda .calendar-empty button", "Set up Calendar")
    refute render(view) =~ "background polling while LOVELACE is running"

    view |> element("#show-connections") |> render_click()
    refute has_element?(view, "#back-from-connections")
    assert has_element?(view, "#center-nav #home-link[aria-label=Home]", "Home")
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#home-overview")
  end

  test "workspace navigation is explicit and reload returns Home", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    assert has_element?(view, "#workspace-list")
    assert has_element?(view, "#show-workspaces[aria-current=page]")
    refute has_element?(view, "#home-overview")
    {:ok, reloaded, _html} = live(conn, ~p"/")
    assert has_element?(reloaded, "#home-overview")
    refute has_element?(reloaded, "#workspace-list")
  end

  test "reconnect retains its last known unread count and observation", %{conn: conn} do
    account = account("stale-reconnect", 9)

    Mail.update_account!(
      account,
      %{expected_generation: account.generation, status: :reconnect, last_error: :reconnect},
      actor: @owner
    )

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-count-#{account.id} .home-unread-number", "9")
    assert has_element?(view, "#home-freshness-#{account.id}[data-failed=true]")
    assert has_element?(view, "#home-health-#{account.id}", "Reconnect required")
    assert has_element?(view, "#home-health-#{account.id} button", "Connections")
    refute_receive {:home_fetch, _}
  end

  defp account(name, count) do
    account =
      Mail.save_connection!(
        %{
          id: Ash.UUID.generate(),
          subject: "home-" <> name,
          email: name <> "@example.test",
          generation: Ash.UUID.generate()
        },
        actor: @owner
      )

    Mail.update_account!(
      account,
      %{
        expected_generation: account.generation,
        inbox_unread_count: count,
        inbox_unread_at: if(is_integer(count), do: DateTime.utc_now(), else: nil)
      },
      actor: @owner
    )
  end
end
