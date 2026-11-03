defmodule LovelaceWeb.CalendarLiveTest do
  use LovelaceWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Lovelace.{Calendar, Mail, Workspaces}
  @owner %{role: :local_owner}

  defmodule FakeIO do
    @moduledoc false
    def get(id), do: {:ok, "synthetic:" <> id}
    def refresh(token), do: {:ok, %{access_token: token}}

    def calendars(token) do
      send(Application.fetch_env!(:lovelace, :calendar_live_owner), {:calendar_provider, token})

      {:ok,
       %{
         calendars: [%{id: "primary", name: "Synthetic shared calendar", selected: true}],
         truncated: false
       }}
    end

    def events(token, "primary", _from, _to) do
      day = Date.utc_today()

      {:ok,
       %{
         events: [
           %{
             id: "same-event",
             title: "<img src='https://calendar-fixture.invalid/image'> " <> token,
             start: Date.to_iso8601(day),
             end: Date.to_iso8601(Date.add(day, 1)),
             all_day: true,
             url: "https://calendar.google.com/calendar/event?eid=synthetic"
           }
         ],
         truncated: false
       }}
    end
  end

  setup %{conn: conn} do
    for {key, value} <- [
          gmail_provider: FakeIO,
          gmail_vault: FakeIO,
          calendar_provider: FakeIO,
          calendar_live_owner: self()
        ] do
      previous = Application.fetch_env(:lovelace, key)
      Application.put_env(:lovelace, key, value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:lovelace, key, value)
          :error -> Application.delete_env(:lovelace, key)
        end
      end)
    end

    a = account("a", true)
    b = account("b", true)
    disabled = account("disabled", false)
    workspace = Workspaces.create_workspace!("Calendar studio", actor: @owner)
    Mail.attach_account!(%{workspace_id: workspace.id, account_id: a.id}, actor: @owner)
    day = Date.utc_today()

    window = %{
      "from" => DateTime.new!(day, ~T[00:00:00]) |> DateTime.to_iso8601(),
      "to" => DateTime.new!(Date.add(day, 1), ~T[00:00:00]) |> DateTime.to_iso8601(),
      "date" => Date.to_iso8601(day),
      "timezone" => "UTC"
    }

    %{
      conn: authenticate_owner(conn),
      a: a,
      b: b,
      disabled: disabled,
      workspace: workspace,
      window: window
    }
  end

  test "day preparation is provider-free, Home stays per-account and events never enter socket assigns",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_hook(view, "calendar:day", ctx.window)
    refute_receive {:calendar_provider, _}
    assert has_element?(view, "#calendar-agenda-account-#{ctx.a.id}", "Updating Calendar")
    refute has_element?(view, "#calendar-agenda-account-#{ctx.disabled.id}")
    poll(ctx.a, ctx.window)
    poll(ctx.b, ctx.window)
    send(view.pid, {:calendar_changed, ctx.a.id})
    html = render(view)
    assert has_element?(view, "#calendar-agenda-account-#{ctx.a.id}", "synthetic:#{ctx.a.id}")
    refute has_element?(view, "#calendar-agenda-account-#{ctx.a.id}", "synthetic:#{ctx.b.id}")
    assert has_element?(view, "#calendar-agenda-account-#{ctx.b.id}", "synthetic:#{ctx.b.id}")
    refute has_element?(view, "#calendar-agenda img")
    refute has_element?(view, "#calendar-agenda button[phx-click='calendar:refresh']")
    refute has_element?(view, "#calendar-agenda", "Last checked")
    assert has_element?(view, "#calendar-agenda [data-warnings-only=true]")
    assert html =~ "&lt;img"
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "calendar-fixture.invalid"
    assert Mail.list_workspace_accounts!(actor: @owner) |> length() == 1
  end

  test "workspace agenda includes attached accounts only and scenery/navigation does not change membership",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_hook(view, "calendar:day", ctx.window)
    poll(ctx.a, ctx.window)
    poll(ctx.b, ctx.window)
    view |> element("#show-workspaces") |> render_click()
    render_click(view, "open_workspace", %{"id" => ctx.workspace.id})
    assert has_element?(view, "#calendar-agenda-account-#{ctx.a.id}")
    assert has_element?(view, "#calendar-agenda button[phx-click='calendar:refresh']", "Refresh")
    assert has_element?(view, "#calendar-agenda [data-warnings-only=false]")
    refute has_element?(view, "#calendar-agenda-account-#{ctx.b.id}")
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#calendar-agenda-account-#{ctx.b.id}")
    refute has_element?(view, "#calendar-agenda button[phx-click='calendar:refresh']")
    assert Mail.list_workspace_accounts!(actor: @owner) |> length() == 1
  end

  test "Calendar Connections is exclusive, optional consent is POST and clearing all selections is valid",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_hook(view, "calendar:day", ctx.window)
    poll(ctx.a, ctx.window)
    view |> element("#show-connections") |> render_click()
    view |> element("#open-connection-calendar") |> render_click()
    assert has_element?(view, "#calendar-connections")
    refute has_element?(view, "#connections-panel, #gemini-connection")

    assert has_element?(
             view,
             "#calendar-connections-authorize-#{ctx.disabled.id}[method=post][action='/oauth/google/start']"
           )

    assert has_element?(
             view,
             "#calendar-connections-authorize-#{ctx.disabled.id} input[name=capability][value=calendar]"
           )

    render_submit(view, "calendar:select", %{"account_id" => ctx.a.id, "calendar_ids" => [""]})

    assert {:ok, snapshot} =
             Calendar.snapshot(ctx.a.id, ctx.window["from"], ctx.window["to"], ctx.window["date"],
               actor: @owner
             )

    assert snapshot.explicit_selection
    assert snapshot.selected_ids == []

    view
    |> element(
      "#calendar-connections-disconnect-help a[href='/connections/gmail'][data-phx-link=patch]"
    )
    |> render_click()

    assert has_element?(view, "#connections-panel")
    refute has_element?(view, "#calendar-connections")
  end

  test "invalid browser contexts are ignored without provider calls", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_hook(view, "calendar:day", %{ctx.window | "to" => ctx.window["from"]})
    refute_receive {:calendar_provider, _}
    assert :sys.get_state(view.pid).socket.assigns.calendar_window == nil
  end

  defp poll(account, window) do
    {:ok, %{revision: revision}} =
      Calendar.prepare(
        account.id,
        window["from"],
        window["to"],
        window["date"],
        window["timezone"],
        actor: @owner
      )

    assert {:ok, _} = Calendar.poll(account.id, account.generation, revision, actor: @owner)
  end

  defp account(label, enabled) do
    Mail.save_connection!(
      %{
        id: Ash.UUID.generate(),
        subject: "calendar-live-" <> label,
        email: label <> "@example.test",
        generation: Ash.UUID.generate(),
        calendar_enabled: enabled
      },
      actor: @owner
    )
  end
end
