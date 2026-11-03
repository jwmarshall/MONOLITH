defmodule LovelaceWeb.ScenesLiveTest do
  use LovelaceWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Settings, Storage}
  alias Lovelace.TestSupport.{GeminiVault, PNG}

  @actor %{role: :stage_designer}
  @now ~U[2026-01-01 12:00:00.000000Z]

  setup %{conn: conn} do
    directory = Path.join(System.tmp_dir!(), "lovelace-scenes-ui-#{Ash.UUID.generate()}")
    previous = Application.get_env(:lovelace, :stage_designer)
    previous_vault = Application.get_env(:lovelace, :gemini_vault)
    start_supervised!(GeminiVault)
    Application.put_env(:lovelace, :gemini_vault, GeminiVault)
    settings = %Settings{enabled: false, storage_dir: directory}
    Application.put_env(:lovelace, :stage_designer, settings)

    on_exit(fn ->
      Application.put_env(:lovelace, :stage_designer, previous)

      if previous_vault,
        do: Application.put_env(:lovelace, :gemini_vault, previous_vault),
        else: Application.delete_env(:lovelace, :gemini_vault)

      File.rm_rf!(directory)
    end)

    %{conn: authenticate_owner(conn), settings: settings, directory: directory}
  end

  test "Scenes is exclusive navigation with a truthful empty state and confirmed-only requests",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    # Forged out-of-view and unconfirmed events cannot reserve an attempt.
    render_click(view, "scenes:confirm", %{})
    assert StageDesigner.get_state!(1, actor: @actor) == nil
    view |> element("#show-scenes") |> render_click()
    render_async(view)
    assert has_element?(view, "#show-scenes[aria-current=page]")
    assert has_element?(view, "#directory-heading", "Scenes")
    assert has_element?(view, "#scenes-empty", "No generated scenes yet")

    assert has_element?(
             view,
             ".scene-toolbar > .scene-status.connection-card[role=status]",
             "No generation is currently confirmed."
           )

    refute has_element?(view, ".scene-status", "Generation is available")
    refute has_element?(view, "#scene-generation-availability")

    assert has_element?(view, "#scene-generate", "Generate scene")
    assert has_element?(view, "#scene-generate [aria-hidden=true] .hero-sparkles")
    refute has_element?(view, "#scene-generate", "…")
    refute has_element?(view, "#scenes-panel", "API charges")
    refute has_element?(view, ".scene-policy")
    refute has_element?(view, "#scenes-panel", "App-wide scenery · All saved scenes")

    refute has_element?(
             view,
             "#home-overview, #workspace-list, #new-workspace, #connections-panel"
           )

    refute has_element?(
             view,
             "#show-workspaces[aria-current], #show-connections[aria-current], #home-link[aria-current]"
           )

    render_click(view, "scenes:confirm", %{})
    assert StageDesigner.get_state!(1, actor: @actor) == nil
    view |> element("#scene-generate") |> render_click()
    assert has_element?(view, "#scene-generation-modal[data-modal]", "may incur API charges")

    assert has_element?(
             view,
             "#scene-generation-modal[data-initial-focus='#scene-generation-cancel']"
           )

    view |> element("#scene-generation-cancel") |> render_click()
    refute has_element?(view, "#scene-generation-modal")
    assert StageDesigner.get_state!(1, actor: @actor) == nil
    view |> element("#show-workspaces") |> render_click()
    assert has_element?(view, "#workspace-list")
    refute has_element?(view, "#scenes-panel")
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#home-overview")
  end

  test "confirmed requests reserve once and surface safe failures without calling Google", %{
    conn: conn
  } do
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "stage_designer")
    {:ok, view, _} = live(conn, "/")
    view |> element("#show-scenes") |> render_click()
    render_async(view)
    view |> element("#scene-generate") |> render_click()
    view |> element("#scene-generation-confirm") |> render_click()
    # The fake vault has no key: generation fails locally, with no provider HTTP.
    assert_receive {:stage_background, %{status: :failed}}, 1_000
    render_async(view)
    assert has_element?(view, "#scenes-panel", "last generation failed")
    assert has_element?(view, "#scene-generate:not([disabled])")
    refute has_element?(view, "#scene-generation-availability")
    refute has_element?(view, "#scene-generate[aria-describedby]")
    refute has_element?(view, "#scene-generation-modal")
    state = StageDesigner.get_state!(1, actor: @actor)
    assert state.status == :failed
    render_click(view, "scenes:confirm", %{})
    render_async(view)
    assert StageDesigner.get_state!(1, actor: @actor) == state

    view |> element("#scene-generate") |> render_click()
    assert has_element?(view, "#scene-generation-modal")
    view |> element("#scene-generation-cancel") |> render_click()
    assert StageDesigner.get_state!(1, actor: @actor) == state
  end

  test "gallery selection updates all connected stages and persists independently of history", %{
    conn: conn,
    settings: settings
  } do
    first = publish(settings, @now, PNG.image(4, 2))
    latest = publish(settings, DateTime.add(@now, 86_400), PNG.image(5, 2))
    {:ok, view, _} = live(conn, "/")
    {:ok, other, _} = live(conn, "/")
    view |> element("#show-scenes") |> render_click()
    render_async(view)
    assert has_element?(view, "#scene-#{latest}[data-active=true]", "Current")
    assert has_element?(view, "#scene-preview-#{first}[phx-hook=StageBackground]")
    assert has_element?(view, "#scene-#{first} time", "2026-01-01 12:00 UTC")
    view |> element("#use-scene-#{first}") |> render_click()
    render_async(view)
    assert has_element?(view, "#scene-#{first}[data-active=true]", "In use")
    assert has_element?(other, "#workspace-background img[src='#{Storage.url(first)}']")
    assert StageDesigner.get_state!(1, actor: @actor).history == [latest, first]
    {:ok, reloaded, _} = live(conn, "/")
    assert has_element?(reloaded, "#workspace-background img[src='#{Storage.url(first)}']")
    view |> element("#show-connections") |> render_click()
    refute has_element?(view, "#scenes-panel, #connections-panel, #connections-subnav")
    assert has_element?(view, "#connections-overview")
  end

  test "a ready scene within 24 hours permits manual requests without reserving on open or cancel",
       %{
         conn: conn,
         settings: settings
       } do
    publish(settings, DateTime.utc_now(), PNG.image())
    state = StageDesigner.get_state!(1, actor: @actor)
    assert state.status == :ready
    {:ok, view, _} = live(conn, "/")
    view |> element("#show-scenes") |> render_click()
    render_async(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    refute has_element?(view, "#scene-generation-availability")
    refute has_element?(view, "#scenes-panel", "Next eligible")
    refute has_element?(view, ".scene-status", "Recent scenery is ready")
    refute has_element?(view, ".scene-status", "No generation is currently confirmed")
    assert has_element?(view, ".scene-status time")
    assert has_element?(view, ".scene-status", "Last attempt:")
    view |> element("#scene-generate") |> render_click()
    assert has_element?(view, "#scene-generation-modal")
    assert StageDesigner.get_state!(1, actor: @actor) == state
    view |> element("#scene-generation-cancel") |> render_click()
    refute has_element?(view, "#scene-generation-modal")
    assert StageDesigner.get_state!(1, actor: @actor) == state
  end

  test "a missing image disables selection but not manual generation", %{
    conn: conn,
    settings: settings,
    directory: directory
  } do
    digest = publish(settings, DateTime.utc_now(), PNG.image())
    state = StageDesigner.get_state!(1, actor: @actor)
    File.write!(Path.join(directory, digest <> ".png"), "damaged synthetic image")
    {:ok, view, _} = live(conn, "/")
    view |> element("#show-scenes") |> render_click()
    render_async(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    assert has_element?(view, "#use-scene-#{digest}[disabled]")
    assert has_element?(view, "#scene-#{digest}", "Local image unavailable")
    refute has_element?(view, "#scene-preview-#{digest}")
    view |> element("#scene-generate") |> render_click()
    assert has_element?(view, "#scene-generation-modal")
    view |> element("#scene-generation-cancel") |> render_click()
    assert StageDesigner.get_state!(1, actor: @actor) == state
    render_click(view, "scenes:select", %{"digest" => String.duplicate("a", 64)})
    render_async(view)
    assert has_element?(view, "#scenes-panel", "could not be selected")
    assert StageDesigner.get_state!(1, actor: @actor).history == [digest]
  end

  test "an unconfirmed generation blocks forged requests until failure is reported", %{
    conn: conn
  } do
    state = StageDesigner.initialize_state!(%{}, actor: @actor)

    reserved =
      StageDesigner.reserve_state!(state, %{last_attempt_at: DateTime.utc_now()}, actor: @actor)

    {:ok, view, _} = live(conn, "/")
    view |> element("#show-scenes") |> render_click()
    render_async(view)
    assert has_element?(view, "#scene-generate[disabled]")

    assert has_element?(
             view,
             "#scene-generation-availability",
             "Another attempt is unconfirmed. A new request is blocked to avoid overlap; refresh status after it resolves."
           )

    render_click(view, "scenes:request", %{})
    refute has_element?(view, "#scene-generation-modal")
    render_click(view, "scenes:confirm", %{})
    render_async(view)
    assert_same_persisted_state(reserved)
    view |> element("#scenes-refresh") |> render_click()
    render_async(view)
    assert has_element?(view, "#scene-generate[disabled]")
    assert_same_persisted_state(reserved)

    failed = StageDesigner.fail_state!(reserved, %{}, actor: @actor)

    Phoenix.PubSub.broadcast(Lovelace.PubSub, "stage_designer", {
      :stage_background,
      StageDesigner.background!()
    })

    render_async(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    assert has_element?(view, "#scenes-panel", "last generation failed")
    assert_same_persisted_state(failed)
  end

  test "navigation and refresh after a failed attempt never generate automatically", %{
    conn: conn,
    settings: settings
  } do
    publish(settings, @now, PNG.image())
    state = StageDesigner.get_state!(1, actor: @actor)

    failed =
      state
      |> StageDesigner.reserve_state!(%{last_attempt_at: DateTime.utc_now()}, actor: @actor)
      |> StageDesigner.fail_state!(%{}, actor: @actor)

    {:ok, view, _} = live(conn, "/")
    view |> element("#show-scenes") |> render_click()
    render_async(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    assert has_element?(view, "#scenes-panel", "last generation failed")
    view |> element("#scenes-refresh") |> render_click()
    render_async(view)
    assert StageDesigner.get_state!(1, actor: @actor) == failed
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#home-overview")
    refute has_element?(view, "#scenes-panel")
    view |> element("#show-workspaces") |> render_click()
    view |> element("#show-connections") |> render_click()
    view |> element("#show-scenes") |> render_click()
    render_async(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    refute has_element?(view, "#scene-generation-modal")
    assert StageDesigner.get_state!(1, actor: @actor) == failed
    {:ok, reloaded, _} = live(conn, "/")
    reloaded |> element("#show-scenes") |> render_click()
    render_async(reloaded)
    assert has_element?(reloaded, "#scene-generate:not([disabled])")
    assert StageDesigner.get_state!(1, actor: @actor) == failed
  end

  test "all saved scenes remain accessible through bounded gallery pages", %{
    conn: conn,
    settings: settings
  } do
    digests =
      for number <- 1..23 do
        publish(settings, DateTime.add(@now, number * 86_400), PNG.image(number + 2, 2))
      end

    oldest = hd(digests)
    {:ok, view, _} = live(conn, "/")
    view |> element("#show-scenes") |> render_click()
    render_async(view)
    assert has_element?(view, "#scenes-panel[data-page='1']")
    assert has_element?(view, "#scene-pagination", "Page 1")
    assert length(:sys.get_state(view.pid).socket.assigns.scene_data.scenes) == 20
    refute has_element?(view, "#scene-#{oldest}")
    view |> element("#scenes-older") |> render_click()
    render_async(view)
    assert has_element?(view, "#scenes-panel[data-page='2']")
    assert length(:sys.get_state(view.pid).socket.assigns.scene_data.scenes) == 3
    assert has_element?(view, "#scenes-older[disabled]")
    assert has_element?(view, "#use-scene-#{oldest}:not([disabled])")
    view |> element("#use-scene-#{oldest}") |> render_click()
    render_async(view)
    assert has_element?(view, "#scene-#{oldest}[data-active=true]", "Current")
    assert has_element?(view, "#workspace-background img[src='#{Storage.url(oldest)}']")
    view |> element("#scenes-newer") |> render_click()
    render_async(view)
    assert has_element?(view, "#scenes-panel[data-page='1']")
    assert has_element?(view, "#scenes-newer[disabled]")
    assert StageDesigner.background!().url == Storage.url(oldest)
  end

  defp assert_same_persisted_state(expected) do
    fields = [
      :id,
      :version,
      :status,
      :last_attempt_at,
      :generated_at,
      :selected_digest,
      :scene_dates,
      :history
    ]

    actual = StageDesigner.get_state!(1, actor: @actor)
    assert Map.take(actual, fields) == Map.take(expected, fields)
  end

  defp publish(settings, now, bytes) do
    state = StageDesigner.initialize_state!(%{}, actor: @actor)
    reserved = StageDesigner.reserve_state!(state, %{last_attempt_at: now}, actor: @actor)
    {:ok, state} = Storage.store_and_publish(settings, bytes, reserved, now)
    hd(state.history)
  end
end
