defmodule LovelaceWeb.HomeLiveTest do
  use LovelaceWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the LOVELACE shell over HTTP", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "script-src 'self'"
    assert policy =~ "font-src 'self'"
    assert policy =~ "object-src 'none'"
    refute policy =~ "unsafe-eval"
    assert html =~ "Workspace · LOVELACE"
    refute html =~ "Welcome to Phoenix"
    assert html =~ ~s(data-theme="lovelace")
    assert conn.resp_cookies["_lovelace_key"]
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
            clientInfo: %{name: "lovelace-test", version: "0.1"}
          }
        })
      )

    assert response(conn, 404)
  end

  test "mounts a minimal glass workspace without marketing or fake features", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workspace.glass-workspace[phx-hook=WorkspaceIdle]")

    assert has_element?(
             view,
             "#workspace[data-idle-minutes][data-workspace-focus][data-workspace-reset]"
           )

    assert has_element?(view, "#workspace-title.sr-only", "LOVELACE")

    assert has_element?(
             view,
             "#workspace-brand[aria-hidden=true][phx-hook=BrandReveal][phx-update=ignore] " <>
               ".workspace-wordmark[aria-label=LOVELACE]"
           )

    assert has_element?(view, "#lovelace-monogram[aria-hidden=true][focusable=false] path")
    refute has_element?(view, ".workspace-heading, header")
    refute has_element?(view, ".workspace-wordmark", "lovelace")
    assert has_element?(view, "#workspace-background[aria-hidden=true]")
    assert has_element?(view, "#main-content[aria-labelledby=workspace-title]")
    assert has_element?(view, "#workspace-instructions", "not connected yet")
    refute has_element?(view, "#accounts-empty, #projects-empty, #sync-status")
    refute has_element?(view, "a", "Private workspace")
    refute has_element?(view, "button", "Send")
  end

  test "provides one traceable stroke and eight ordered flip-up letters", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#lovelace-monogram-stroke")

    for {letter, index} <- Enum.with_index(String.graphemes("LOVELACE")) do
      assert has_element?(view, "#lovelace-letter-#{index}.workspace-letter", letter)
    end

    refute has_element?(view, ".workspace-wordmark .workspace-letter:nth-child(9)")
  end

  test "offers keyboard-accessible client-side focus and an Escape reset", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "a[href='#workspace-pane']", "Skip to workspace")

    assert has_element?(
             view,
             "#workspace-pane[type=button][aria-pressed=false][aria-describedby=workspace-instructions]"
           )

    assert has_element?(view, "#workspace-pane[phx-click][phx-focus]")
    assert has_element?(view, "#workspace-pane[phx-window-keydown][phx-key=Escape]")
  end

  test "exposes configurable idle duration and shared sticky focus/reset commands", %{conn: conn} do
    previous = Application.fetch_env(:lovelace, :workspace_idle_minutes)
    Application.put_env(:lovelace, :workspace_idle_minutes, 7)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lovelace, :workspace_idle_minutes, value)
        :error -> Application.delete_env(:lovelace, :workspace_idle_minutes)
      end
    end)

    {:ok, view, html} = live(conn, ~p"/")
    assert has_element?(view, "#workspace[data-idle-minutes='7']")

    root = html |> LazyHTML.from_fragment() |> LazyHTML.query("#workspace")

    for {attribute, pressed, event} <- [
          {"data-workspace-focus", "true", "lovelace:brand-focus"},
          {"data-workspace-reset", "false", "lovelace:brand-reset"}
        ] do
      [commands] = LazyHTML.attribute(root, attribute)

      assert Jason.decode!(commands) == [
               ["set_attr", %{"attr" => ["aria-pressed", pressed], "to" => "#workspace-pane"}],
               ["dispatch", %{"event" => event, "to" => "#workspace-brand"}]
             ]
    end
  end

  test "fetches the current stage background on mount", %{conn: conn} do
    {:ok, background} = Lovelace.StageDesigner.background()
    {:ok, view, _html} = live(conn, ~p"/")

    if background.url do
      assert has_element?(view, "#workspace-background img[src='#{background.url}']")
    else
      refute has_element?(view, "#workspace-background img")
    end

    assert has_element?(view, "#stage-background-status.sr-only[role=status][aria-live=polite]")
  end

  test "receives local stage updates through PubSub with original scenery as fallback", %{
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
    Phoenix.PubSub.broadcast(Lovelace.PubSub, "stage_designer", {:stage_background, background})
  end

  test "serves the double cursive l favicon", %{conn: conn} do
    conn = get(conn, ~p"/favicon.svg")

    assert response(conn, 200) =~ ~s(viewBox="0 0 104 104")
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/svg+xml"
  end

  test "serves the self-hosted Space Grotesk font", %{conn: conn} do
    conn = get(conn, ~p"/fonts/space-grotesk/space-grotesk-variable.woff2")

    assert <<"wOF2", _font_data::binary>> = response(conn, 200)
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "font/woff2"
  end

  test "serves the scenery locally", %{conn: conn} do
    conn = get(conn, ~p"/images/distant-shore.svg")

    assert response(conn, 200) =~ "<svg"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/svg+xml"
  end
end
