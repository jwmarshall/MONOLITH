defmodule LovelaceWeb.WorkspacesLiveTest do
  use LovelaceWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Lovelace.Workspaces

  @owner %{role: :local_owner}
  @personal_id "00000000-0000-4000-8000-000000000001"

  test "initializes Personal once and preserves its renamed name on reconnect", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#open-#{@personal_id}", "Personal")

    view |> element("#rename-#{@personal_id}") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "My quiet corner"}) |> render_submit()
    assert has_element?(view, "#open-#{@personal_id}", "My quiet corner")

    {:ok, reopened, _html} = live(conn, ~p"/")
    assert has_element?(reopened, "#open-#{@personal_id}", "My quiet corner")
    assert length(Workspaces.list_workspaces!(actor: @owner)) == 1
  end

  test "creates, opens, renames and returns to the directory", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#new-workspace") |> render_click()
    assert has_element?(view, "#workspace-name[required][maxlength='64']")
    view |> form("#workspace-form", workspace: %{name: "  Studio  "}) |> render_submit()
    refute has_element?(view, "#workspace-form")

    studio = Enum.find(Workspaces.list_workspaces!(actor: @owner), &(&1.name == "Studio"))
    view |> element("#open-#{studio.id}") |> render_click()
    assert has_element?(view, "#directory-heading", "Studio")
    assert has_element?(view, "#workspace-landing", "not connected")
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
    assert has_element?(view, "#open-#{workspace.id}", "<script>alert(1)</script>")
    refute has_element?(view, "#workspace-content script")
  end

  test "missing and malformed workspace IDs do not crash or open another space", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for id <- [Ash.UUID.generate(), "not-a-uuid"] do
      render_click(view, "open_workspace", %{"id" => id})
      refute has_element?(view, "#workspace-landing")
      assert has_element?(view, "#flash-error", "unavailable")
      render_click(view, "rename_workspace", %{"id" => id})
      refute has_element?(view, "#workspace-form")
    end
  end

  test "background updates preserve the current workspace and unsaved form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
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
