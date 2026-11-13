defmodule MonolithWeb.WorkspacesLiveTest do
  use MonolithWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn}, do: {:ok, conn: authenticate_owner(conn)}

  alias Monolith.Workspaces

  @owner %{role: :local_owner}

  test "Home and an empty directory never manufacture a starter workspace", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert Workspaces.list_workspaces!(actor: @owner) == []
    view |> element("#show-workspaces") |> render_click()
    refute has_element?(view, ".workspace-card-name")
    assert Workspaces.list_workspaces!(actor: @owner) == []
    render_click(view, "retry_workspaces")
    assert Workspaces.list_workspaces!(actor: @owner) == []
  end

  test "preserves an explicitly created workspace and renamed name on reconnect", %{conn: conn} do
    workspace = Workspaces.create_workspace!("Reading room", actor: @owner)
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-overview")
    view |> element("#show-workspaces") |> render_click()
    assert has_element?(view, "#open-#{workspace.id}", "Reading room")

    view |> element("#rename-#{workspace.id}") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "My quiet corner"}) |> render_submit()
    assert has_element?(view, "#open-#{workspace.id}", "My quiet corner")

    {:ok, reopened, _html} = live(conn, ~p"/")
    assert has_element?(reopened, "#home-overview")
    refute has_element?(reopened, "#workspace-list")
    reopened |> element("#show-workspaces") |> render_click()
    assert has_element?(reopened, "#open-#{workspace.id}", "My quiet corner")
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

    refute has_element?(view, "#workspace-list")

    view |> element("#rename-current-workspace") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "Observatory"}) |> render_submit()
    assert has_element?(view, "#directory-heading", "Observatory")
    view |> element("#back-to-workspaces") |> render_click()
    assert has_element?(view, "#open-#{studio.id}", "Observatory")
    assert length(Workspaces.list_workspaces!(actor: @owner)) == 1
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
      assert has_element?(view, "#workspace-form-feedback a[href='#workspace-name']")

      assert has_element?(
               view,
               "#workspace-name[aria-invalid=true][aria-describedby~='workspace-name-hint'][aria-describedby~='workspace-form-feedback']"
             )

      assert Workspaces.list_workspaces!(actor: @owner) == []
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
    workspace = Workspaces.create_workspace!("Studio", actor: @owner)
    {:ok, view, _html} = live(conn, ~p"/")
    assert_push_event(view, "workspace:focus-heading", %{})
    view |> element("#show-workspaces") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    view |> element("#open-#{workspace.id}") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})

    view |> element("#show-connections") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    render_patch(view, "/workspaces/#{workspace.id}")
    assert_push_event(view, "workspace:focus-heading", %{})

    view |> element("#rename-current-workspace") |> render_click()
    assert has_element?(view, "#workspace-modal-title", "Rename workspace")

    assert has_element?(
             view,
             "#workspace-modal[data-return-focus='#rename-current-workspace']"
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
    assert Workspaces.list_workspaces!(actor: @owner) == []
  end

  test "Cancel and reopen preserve separate new and rename drafts without saving them", %{
    conn: conn
  } do
    workspace = Workspaces.create_workspace!("Studio", actor: @owner)
    {:ok, view, _html} = live(conn, ~p"/workspaces")

    view |> element("#new-workspace") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "New draft"}) |> render_change()
    view |> element("#workspace-form button[type=button]") |> render_click()
    refute has_element?(view, "#workspace-modal")
    assert Workspaces.list_workspaces!(actor: @owner) |> length() == 1

    view |> element("#rename-#{workspace.id}") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "Rename draft"}) |> render_change()
    view |> element("#workspace-form button[type=button]") |> render_click()
    assert has_element?(view, "#open-#{workspace.id}", "Studio")

    view |> element("#new-workspace") |> render_click()
    assert has_element?(view, "#workspace-name[value='New draft']")
    view |> form("#workspace-form", workspace: %{name: "New workspace"}) |> render_submit()

    view |> element("#rename-#{workspace.id}") |> render_click()
    assert has_element?(view, "#workspace-name[value='Rename draft']")
    view |> form("#workspace-form", workspace: %{name: "Renamed studio"}) |> render_submit()
    assert has_element?(view, "#open-#{workspace.id}", "Renamed studio")

    view |> element("#new-workspace") |> render_click()
    refute has_element?(view, "#workspace-name[value='New draft']")
    view |> element("#workspace-form button[type=button]") |> render_click()

    view |> element("#rename-#{workspace.id}") |> render_click()
    assert has_element?(view, "#workspace-name[value='Renamed studio']")
    assert Workspaces.list_workspaces!(actor: @owner) |> length() == 2
  end

  test "background updates preserve the current workspace and unsaved form", %{conn: conn} do
    workspace = Workspaces.create_workspace!("Studio", actor: @owner)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    view |> element("#open-#{workspace.id}") |> render_click()
    view |> element("#rename-current-workspace") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "Not saved yet"}) |> render_change()

    Phoenix.PubSub.broadcast(
      Monolith.PubSub,
      "stage_designer",
      {:stage_background, %{url: nil, status: :failed}}
    )

    assert has_element?(view, "#directory-heading", "Studio")
    assert has_element?(view, "#workspace-name[value='Not saved yet']")
    assert has_element?(view, "#workspace-brand[phx-update=ignore]")
  end
end
