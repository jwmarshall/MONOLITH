defmodule MonolithWeb.HomeLiveTest do
  use MonolithWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monolith.StageDesigner.BundledScenes

  setup %{conn: conn}, do: {:ok, conn: authenticate_owner(conn)}

  test "serves the shell with self-hosted assets and a restrictive CSP", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "script-src 'self'"
    assert policy =~ "font-src 'self'"
    assert policy =~ "object-src 'none'"
    refute policy =~ "unsafe-eval"
    assert conn.resp_cookies["_monolith_key"]
    assert html =~ ~s(id="workspace-background")
    assert html =~ ~s(href="/fonts/space-grotesk/space-grotesk-variable.woff2")
    assert html =~ ~s(as="font" type="font/woff2" crossorigin="anonymous")
  end

  test "development MCP tools are absent in the test environment", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/tidewave/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            protocolVersion: "2025-03-26",
            capabilities: %{},
            clientInfo: %{name: "monolith-test", version: "0.1"}
          }
        })
      )

    assert response(conn, 404)
  end

  test "mounts the glass entrance with gated Home and no fake integrations", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workspace.glass-workspace[phx-hook=WorkspaceIdle]")

    assert has_element?(
             view,
             "#workspace[data-idle-minutes][data-workspace-focus][data-workspace-reset]"
           )

    assert has_element?(view, "#workspace-title.sr-only", "MONOLITH")
    assert has_element?(view, "#workspace-content[inert]")

    assert has_element?(
             view,
             "#product-sidebar #home-link[href='/'][data-phx-link=patch][aria-current=page]",
             "Home"
           )

    assert has_element?(view, "#product-sidebar[aria-label='Product navigation']")

    assert has_element?(
             view,
             "#sidebar-toggle[type=button][aria-expanded=false][aria-controls=sidebar-content]"
           )

    assert has_element?(
             view,
             "#sidebar-content[hidden] nav[aria-label='Main navigation'] #show-workspaces"
           )

    assert has_element?(view, "#sidebar-content #show-connections")
    assert has_element?(view, "#sidebar-content #show-scenes")
    assert has_element?(view, "#sidebar-content #show-settings")

    assert has_element?(
             view,
             "#daily-heading[phx-hook=DailyOrientation][phx-update=ignore] " <>
               "#directory-heading[data-workspace-heading][tabindex='-1']"
           )

    assert has_element?(view, "#daily-heading time[data-daily-date]")
    assert has_element?(view, "#home-overview #home-empty")
    refute has_element?(view, "#workspace-list, #workspace-landing, #home-inbox")
    assert has_element?(view, "#workspace-background[aria-hidden=true]")
    assert has_element?(view, "#main-content[aria-labelledby=workspace-title]")
    assert has_element?(view, "#workspace-instructions", "resume your current view")
    refute has_element?(view, "#accounts-empty, #projects-empty, #sync-status")
    refute has_element?(view, "a", "Private workspace")
    refute has_element?(view, "button", "Send")

    view |> element("#show-workspaces") |> render_click()
    assert has_element?(view, "#workspace-list[phx-update=stream]")
    assert has_element?(view, "#directory-heading", "Workspaces")
    refute has_element?(view, ".workspace-card-name")
    assert Monolith.Workspaces.list_workspaces!(actor: %{role: :local_owner}) == []
    refute has_element?(view, "#home-link[aria-current=page], #home-overview")

    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#home-overview #home-empty")
    assert has_element?(view, "#home-link[aria-current=page]")
    assert_push_event(view, "workspace:focus-heading", %{})
  end

  test "offers keyboard-accessible client-side focus and an Escape reset", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "a[href='#main-content']", "Skip to workspace")

    assert has_element?(
             view,
             "#workspace-pane[type=button][aria-pressed=false][aria-describedby=workspace-instructions]"
           )

    assert has_element?(view, "#workspace-pane[phx-click][phx-focus]")
    assert has_element?(view, "#main-content[phx-hook=WorkspaceEntrance]")
  end

  test "Lock is a CSRF-protected POST inside the working gate, never a scenery reset", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#workspace-content[inert] .page-header-row #owner-lock-form[action='/lock'][method=post]"
           )

    assert has_element?(view, "#owner-lock-form input[type=hidden][name=_csrf_token]")
    assert has_element?(view, "#owner-lock-form button[type=submit]", "Lock")
    refute has_element?(view, "#owner-lock-form[phx-click], #owner-lock-form button[phx-click]")
  end

  test "uses the configured default idle duration", %{conn: conn} do
    previous = Application.fetch_env(:monolith, :workspace_idle_minutes)
    Application.put_env(:monolith, :workspace_idle_minutes, 7)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:monolith, :workspace_idle_minutes, value)
        :error -> Application.delete_env(:monolith, :workspace_idle_minutes)
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#workspace[data-idle-minutes='7']")
  end

  test "fetches the current stage background on mount", %{conn: conn} do
    {:ok, background} = Monolith.StageDesigner.background()
    {:ok, view, _html} = live(conn, ~p"/")

    if background.url do
      assert has_element?(view, "#workspace-background img[src='#{background.url}']")
    else
      refute has_element?(view, "#workspace-background img")
    end

    assert has_element?(view, "#stage-background-status.sr-only[role=status][aria-live=polite]")
  end

  test "receives local stage updates through PubSub with bundled scenery as fallback", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    url = "/stage/background/#{String.duplicate("a", 64)}.png"

    broadcast_background(%{url: url, status: :ready})

    assert has_element?(
             view,
             "#workspace-background img[src='#{url}'][phx-hook=StageBackground][alt='']"
           )

    assert has_element?(view, "#workspace-brand[phx-update=ignore]")

    broadcast_background(%{url: url, status: :pending})
    assert has_element?(view, "#stage-background-status", "Preparing")
    assert has_element?(view, "#workspace-background img[src='#{url}']")

    broadcast_background(%{url: url, status: :failed})
    assert has_element?(view, "#stage-background-status", "unavailable")
    assert has_element?(view, "#workspace-background img[src='#{url}']")

    broadcast_background(%{url: nil, status: :failed})
    refute has_element?(view, "#workspace-background img")
    assert has_element?(view, "#workspace-background[aria-hidden=true]")
    assert has_element?(view, "#workspace-background[style*=\"/images/scenes/\"]")
  end

  test "an interrupted attempt is not announced as active preparation on mount", %{conn: conn} do
    alias Monolith.StageDesigner
    alias Monolith.StageDesigner.Settings
    actor = %{role: :stage_designer}
    previous = Application.fetch_env!(:monolith, :stage_designer)

    Application.put_env(:monolith, :stage_designer, %Settings{
      enabled: true,
      storage_dir: Path.join(System.tmp_dir!(), "monolith-uncertain-#{Ash.UUID.generate()}")
    })

    on_exit(fn -> Application.put_env(:monolith, :stage_designer, previous) end)

    StageDesigner.initialize_state!(%{}, actor: actor)
    |> StageDesigner.reserve_state!(%{last_attempt_at: ~U[2026-11-01 12:00:00.000000Z]},
      actor: actor
    )

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#stage-background-status", "no confirmed outcome")
    refute has_element?(view, "#stage-background-status", "Preparing")
    assert StageDesigner.get_state!(1, actor: actor).status == :generating
  end

  test "receives canonical JPEG stage updates through PubSub with the same image hook", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    url = "/stage/background/#{String.duplicate("b", 64)}.jpg"

    broadcast_background(%{url: url, status: :ready})

    assert has_element?(
             view,
             "#workspace-background img.workspace-background-image[src='#{url}']" <>
               "[phx-hook=StageBackground][alt='']"
           )

    assert has_element?(view, "#workspace-brand[phx-update=ignore]")
    assert has_element?(view, "#workspace[phx-hook=WorkspaceIdle]")
  end

  test "rejects arbitrary or external background URLs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for url <- [
          "https://example.com/background.png",
          "//example.com/background.png",
          "/images/untrusted.svg",
          "/stage/background/#{String.duplicate("A", 64)}.png",
          "/stage/background/#{String.duplicate("a", 64)}.png?redirect=external",
          "/stage/background/#{String.duplicate("a", 64)}.png\n",
          "/stage/background/#{String.duplicate("a", 64)}.jpeg",
          "/stage/background/#{String.duplicate("a", 64)}.svg",
          "/stage/background/#{String.duplicate("a", 64)}.JPG",
          "/stage/background/#{String.duplicate("A", 64)}.jpg",
          "/stage/background/#{String.duplicate("a", 63)}.jpg",
          "/stage/background/#{String.duplicate("a", 65)}.jpg",
          "/stage/background/#{String.duplicate("g", 64)}.jpg",
          "/stage/background/#{String.duplicate("a", 64)}.jpg?redirect=external",
          "/stage/background/#{String.duplicate("a", 64)}.jpg#fragment",
          " /stage/background/#{String.duplicate("a", 64)}.jpg",
          "/stage/background/#{String.duplicate("a", 64)}.jpg ",
          "/stage/background/#{String.duplicate("a", 64)}.jpg\n"
        ] do
      broadcast_background(%{url: url, status: :ready})
      refute has_element?(view, "#workspace-background img")
    end
  end

  defp broadcast_background(background) do
    Phoenix.PubSub.broadcast(Monolith.PubSub, "stage_designer", {:stage_background, background})
  end

  test "serves the self-hosted SVG favicon", %{conn: conn} do
    conn = get(conn, ~p"/favicon.svg")

    assert response(conn, 200)
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/svg+xml"
  end

  test "serves the self-hosted Space Grotesk font", %{conn: conn} do
    conn = get(conn, ~p"/fonts/space-grotesk/space-grotesk-variable.woff2")

    assert <<"wOF2", _font_data::binary>> = response(conn, 200)
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "font/woff2"
  end

  test "serves all bundled default scenes locally without a scene catalog", %{conn: conn} do
    for digest <- BundledScenes.digests() do
      scene = get(conn, "/images/scenes/#{digest}.jpg")
      assert <<0xFF, 0xD8, _::binary>> = response(scene, 200)
      assert get_resp_header(scene, "content-type") == ["image/jpeg"]
      assert Base.encode16(:crypto.hash(:sha256, scene.resp_body), case: :lower) == digest
    end
  end
end
