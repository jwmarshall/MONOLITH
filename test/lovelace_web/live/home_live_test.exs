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

    assert has_element?(view, "#workspace.glass-workspace")
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
