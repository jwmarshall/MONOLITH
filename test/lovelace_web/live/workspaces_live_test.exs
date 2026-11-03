defmodule LovelaceWeb.WorkspacesLiveTest do
  use LovelaceWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn}, do: {:ok, conn: authenticate_owner(conn)}

  alias Lovelace.Workspaces

  @owner %{role: :local_owner}
  @personal_id "00000000-0000-4000-8000-000000000001"

  test "initializes Personal once and preserves its renamed name on reconnect", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-overview")
    view |> element("#show-workspaces") |> render_click()
    assert has_element?(view, "#open-#{@personal_id}", "Personal")

    view |> element("#rename-#{@personal_id}") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "My quiet corner"}) |> render_submit()
    assert has_element?(view, "#open-#{@personal_id}", "My quiet corner")

    {:ok, reopened, _html} = live(conn, ~p"/")
    assert has_element?(reopened, "#home-overview")
    refute has_element?(reopened, "#workspace-list")
    reopened |> element("#show-workspaces") |> render_click()
    assert has_element?(reopened, "#open-#{@personal_id}", "My quiet corner")
    assert length(Workspaces.list_workspaces!(actor: @owner)) == 1
  end

  test "creates, opens, renames and returns to the directory", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    view |> element("#new-workspace") |> render_click()
    assert has_element?(view, "#workspace-name[required][maxlength='64']")

    assert has_element?(
             view,
             "dialog#workspace-modal[phx-hook=NativeModal][aria-labelledby=workspace-modal-title][data-cancel-event=cancel_workspace][data-return-focus='#new-workspace']"
           )

    assert has_element?(view, "#workspace-modal-title", "New workspace")
    assert has_element?(view, "#workspace-modal #workspace-form")
    view |> form("#workspace-form", workspace: %{name: "  Studio  "}) |> render_submit()
    refute has_element?(view, "#workspace-form")

    studio = Enum.find(Workspaces.list_workspaces!(actor: @owner), &(&1.name == "Studio"))
    view |> element("#open-#{studio.id}") |> render_click()
    assert has_element?(view, "#directory-heading", "Studio")
    assert has_element?(view, "#workspace-landing", "Gmail")
    assert has_element?(view, "#workspace > #workspace-background.workspace-background")
    assert has_element?(view, "#workspace > #workspace-monogram.stage-monogram path")
    refute has_element?(view, ".workspace-signature")

    assert has_element?(
             view,
             "#workspace > #main-content.workspace-glass #workspace-content #mail-accounts",
             "No accounts attached yet"
           )

    refute has_element?(view, "#workspace-list")

    view |> element("#rename-current-workspace") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "Observatory"}) |> render_submit()
    assert has_element?(view, "#directory-heading", "Observatory")
    view |> element("#back-to-workspaces") |> render_click()
    assert has_element?(view, "#open-#{studio.id}", "Observatory")
    assert has_element?(view, "#open-#{@personal_id}", "Personal")
    assert length(Workspaces.list_workspaces!(actor: @owner)) == 2
  end

  test "validates names on the server without losing the editor or writing records", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    view |> element("#new-workspace") |> render_click()

    for name <- ["   ", String.duplicate("a", 65)] do
      view |> form("#workspace-form", workspace: %{name: name}) |> render_change()
      view |> form("#workspace-form", workspace: %{name: name}) |> render_submit()
      assert has_element?(view, "#workspace-form")
      assert has_element?(view, "#workspace-form-feedback[role=alert]", "couldn’t be saved")

      assert has_element?(
               view,
               "#workspace-name[aria-invalid=true][aria-describedby='workspace-name-hint workspace-form-feedback']"
             )

      assert length(Workspaces.list_workspaces!(actor: @owner)) == 1
    end

    view |> element("#workspace-form button[type=button]") |> render_click()
    refute has_element?(view, "#workspace-form")
  end

  test "treats workspace names as text, not markup", %{conn: conn} do
    workspace = Workspaces.create_workspace!("<script>alert(1)</script>", actor: @owner)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    assert has_element?(view, "#open-#{workspace.id}", "<script>alert(1)</script>")
    refute has_element?(view, "#workspace-content script")
  end

  test "missing and malformed workspace IDs do not crash or open another space", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()

    for id <- [Ash.UUID.generate(), "not-a-uuid"] do
      render_click(view, "open_workspace", %{"id" => id})
      refute has_element?(view, "#workspace-landing")
      assert has_element?(view, "#flash-error", "unavailable")
      render_click(view, "rename_workspace", %{"id" => id})
      refute has_element?(view, "#workspace-form")
    end
  end

  test "navigation requests heading focus but modal save, cancel and validation leave restoration to the hook",
       %{
         conn: conn
       } do
    {:ok, view, _html} = live(conn, ~p"/")
    assert_push_event(view, "workspace:focus-heading", %{})
    view |> element("#show-workspaces") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    view |> element("#open-#{@personal_id}") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})

    view |> element("#show-connections") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    render_patch(view, "/workspaces/#{@personal_id}")
    assert_push_event(view, "workspace:focus-heading", %{})

    view |> element("#rename-current-workspace") |> render_click()
    assert has_element?(view, "#workspace-modal-title", "Rename workspace")

    assert has_element?(
             view,
             "#workspace-modal[data-return-focus='#workspace-menu-#{@personal_id} summary']"
           )

    view |> form("#workspace-form", workspace: %{name: "   "}) |> render_submit()
    assert has_element?(view, "#workspace-name[aria-invalid=true]")
    refute_push_event(view, "workspace:focus-heading", %{})

    view |> form("#workspace-form", workspace: %{name: "Renamed"}) |> render_submit()
    refute has_element?(view, "#workspace-modal")
    refute_push_event(view, "workspace:focus-heading", %{})

    assert has_element?(
             view,
             "#directory-heading[data-workspace-heading][tabindex='-1']",
             "Renamed"
           )

    view |> element("#rename-current-workspace") |> render_click()
    view |> element("#workspace-form button[type=button]") |> render_click()
    refute_push_event(view, "workspace:focus-heading", %{})
    refute has_element?(view, "#workspace-form")

    view |> element("#back-to-workspaces") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    view |> element("#show-connections") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    refute has_element?(view, "#back-from-connections")
    view |> element("#home-link") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    assert has_element?(view, "#home-overview")
    refute has_element?(view, "#workspace-list")
    view |> element("#show-workspaces") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    assert has_element?(view, "#workspace-list")
  end

  test "unrelated directory updates preserve modal drafts and validation errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert_push_event(view, "workspace:focus-heading", %{})
    view |> element("#show-workspaces") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    view |> element("#new-workspace") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "Not saved yet"}) |> render_change()
    render_click(view, "retry_workspaces")
    assert has_element?(view, "#workspace-modal #workspace-name[value='Not saved yet']")

    invalid_name = String.duplicate("x", 65)
    view |> form("#workspace-form", workspace: %{name: invalid_name}) |> render_change()
    view |> form("#workspace-form", workspace: %{name: invalid_name}) |> render_submit()
    render_click(view, "retry_workspaces")

    assert has_element?(
             view,
             "#workspace-modal #workspace-name[aria-invalid=true][value='#{invalid_name}']"
           )

    assert has_element?(view, "#workspace-form-feedback[role=alert]", "couldn’t be saved")
    refute_push_event(view, "workspace:focus-heading", %{})
    assert length(Workspaces.list_workspaces!(actor: @owner)) == 1
  end

  test "background updates preserve the current workspace and unsaved form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    view |> element("#open-#{@personal_id}") |> render_click()
    view |> element("#rename-current-workspace") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "Not saved yet"}) |> render_change()

    Phoenix.PubSub.broadcast(
      Lovelace.PubSub,
      "stage_designer",
      {:stage_background, %{url: nil, status: :failed}}
    )

    assert has_element?(view, "#directory-heading", "Personal")
    assert has_element?(view, "#workspace-name[value='Not saved yet']")
    assert has_element?(view, "#workspace-brand[phx-update=ignore]")
  end
end
