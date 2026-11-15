defmodule MonolithWeb.CacheSettingsTest do
  use MonolithWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Monolith.Caching
  @owner %{role: :local_owner}

  test "settings save independent policies, preserve rejected drafts and reload persisted values",
       %{conn: conn} do
    conn = authenticate_owner(conn)
    {:ok, view, _} = live(conn, "/settings/cache")
    assert has_element?(view, "#cache-gmail-refresh[value='3']")
    assert has_element?(view, "#cache-github-refresh[min='5']")

    view
    |> form("#cache-gmail", cache: %{refresh_minutes: "10", retention_hours: "6"})
    |> render_submit()

    assert has_element?(view, "#cache-gmail-status[role=status]")
    assert Caching.policy!(:gmail).refresh_seconds == 600
    assert Caching.policy!(:gmail).retention_seconds == 21_600
    assert Caching.policy!(:calendar).refresh_seconds == 180

    # Forged submissions must be checked on the server, not only by native inputs.
    render_submit(view, "settings:cache", %{
      "integration" => "github",
      "cache" => %{"refresh_minutes" => "4", "retention_hours" => "24"}
    })

    assert has_element?(view, "#cache-github-error[role=alert]")
    assert has_element?(view, "#cache-github-refresh[value='4'][aria-invalid=true]")
    assert Caching.policy!(:github).refresh_minutes == 5
    assert Caching.policy!(:gmail).refresh_minutes == 10
    assert has_element?(view, "#cache-github-retention[value='24'][aria-invalid=false]")
    assert has_element?(view, "#cache-github-refresh-error")
    refute has_element?(view, "#cache-github-retention-error")

    view
    |> form("#cache-calendar", cache: %{refresh_minutes: "20", retention_hours: "12"})
    |> render_change()

    view
    |> form("#cache-gmail", cache: %{refresh_minutes: "15", retention_hours: "6"})
    |> render_submit()

    assert has_element?(view, "#cache-calendar-refresh[value='20']")
    assert has_element?(view, "#cache-calendar-retention[value='12']")
    assert Caching.policy!(:calendar).refresh_minutes == 3

    {:ok, reloaded, _} = live(conn, "/settings/cache")
    assert has_element?(reloaded, "#cache-gmail-refresh[value='15']")
    assert has_element?(reloaded, "#cache-gmail-retention[value='6']")
    refute has_element?(reloaded, "#cache-github-error")
    assert [%{integration: :gmail}] = Caching.preferences!(actor: @owner)

    render_patch(reloaded, "/")

    render_submit(reloaded, "settings:cache", %{
      "integration" => "gmail",
      "cache" => %{"refresh_minutes" => "60", "retention_hours" => "1"}
    })

    assert Caching.policy!(:gmail).refresh_minutes == 15
  end

  test "cache events cannot save or seed drafts outside the cache child", %{conn: conn} do
    conn = authenticate_owner(conn)
    {:ok, view, _} = live(conn, "/settings/cache")

    for path <- ["/settings", "/settings/focus", "/settings/startup", "/"] do
      render_patch(view, path)
      refute has_element?(view, "#cache-gmail, #cache-calendar, #cache-github")

      params = %{
        "integration" => "gmail",
        "cache" => %{"refresh_minutes" => "60", "retention_hours" => "1"}
      }

      render_change(view, "settings:cache-draft", params)
      render_submit(view, "settings:cache", params)
      assert Caching.preferences!(actor: @owner) == []
      assert Caching.policy!(:gmail).refresh_minutes == 3

      render_patch(view, "/settings/cache")
      assert has_element?(view, "#cache-gmail-refresh[value='3']")
      refute has_element?(view, "#cache-gmail-refresh[value='60']")
    end
  end
end
