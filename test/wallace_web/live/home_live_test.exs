defmodule WallaceWeb.HomeLiveTest do
  use WallaceWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the Wallace shell over HTTP", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "script-src 'self'"
    assert policy =~ "object-src 'none'"
    refute policy =~ "unsafe-eval"
    assert html =~ "Workspace · Wallace"
    assert html =~ ~s(data-theme="wallace")
    assert html =~ "Private workspace"
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
            clientInfo: %{name: "wallace-test", version: "0.1"}
          }
        })
      )

    assert response(conn, 404)
  end

  test "mounts the live workspace with honest unconfigured states", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#workspace-title", "Space for deliberate work.")
    assert has_element?(view, "#accounts-empty", "No accounts connected.")
    assert has_element?(view, "#projects-empty", "Projects")
    assert has_element?(view, "#sync-status", "Not configured.")
    refute has_element?(view, "button", "Send")
  end
end
