defmodule LovelaceWeb.ScenesLiveTest do
  use LovelaceWeb.ConnCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite
  import Phoenix.LiveViewTest
  import Lovelace.TestSupport.BackgroundWork, only: [complete: 1]

  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{Attempt, Generation, GenerationWorker, Models, Settings, Storage}
  alias Lovelace.TestSupport.{GeminiVault, PNG, SceneGeneration}

  @actor %{role: :stage_designer}
  @now ~U[2026-01-01 12:00:00.000000Z]

  setup %{conn: conn} do
    directory = Path.join(System.tmp_dir!(), "lovelace-scenes-ui-#{Ash.UUID.generate()}")
    previous = Application.get_env(:lovelace, :stage_designer)
    previous_vault = Application.get_env(:lovelace, :gemini_vault)
    start_supervised!(GeminiVault)
    Application.put_env(:lovelace, :gemini_vault, GeminiVault)
    assert :ok = GeminiVault.put("unused", "synthetic-scenes-key")
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
    complete(view)
    assert has_element?(view, "#show-scenes[aria-current=page]")
    assert has_element?(view, "#directory-heading", "Scenes")
    assert has_element?(view, "#scenes-empty", "No generated scenes yet")
    refute has_element?(view, "#scene-gemini-setup")

    assert has_element?(view, ".scene-toolbar > .scene-status.connection-card[role=status]")

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
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
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

  test "Scenes switches between setup-only and the configured designer without exposing the key",
       %{
         conn: conn,
         settings: settings
       } do
    key = "synthetic-scenes-key-never-rendered"
    assert :ok = GeminiVault.put("unused", key)
    digest = publish(settings, @now, PNG.image())
    {:ok, view, _} = live(conn, "/scenes")
    html = complete(view)

    refute has_element?(view, "#scene-gemini-setup")
    refute html =~ key
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ key
    assert has_element?(view, "#scene-direction-form")
    assert has_element?(view, "#scene-generation-settings")
    assert has_element?(view, "#scene-gallery #scene-#{digest}")
    assert has_element?(view, "#scene-attempt-history")
    state = StageDesigner.get_state!(1, actor: @actor)

    assert :ok = GeminiVault.delete("unused")
    view |> element("#scenes-refresh") |> render_click()
    complete(view)
    assert has_element?(view, "#scene-gemini-setup", "No Gemini API key is stored")
    assert_setup_only(view)
    assert StageDesigner.get_state!(1, actor: @actor) == state

    view |> element("#scene-gemini-setup a") |> render_click()
    assert_patch(view, "/connections/gemini")
    assert :ok = GeminiVault.put("unused", key)
    view |> element("#show-scenes") |> render_click()
    html = complete(view)
    refute has_element?(view, "#scene-gemini-setup")
    assert has_element?(view, "#scene-direction-form")
    assert has_element?(view, "#scene-generation-settings")
    assert has_element?(view, "#scene-gallery #scene-#{digest}")
    assert has_element?(view, "#scene-attempt-history")
    refute html =~ key
    assert StageDesigner.get_state!(1, actor: @actor) == state
  end

  test "Scenes stays setup-only until the local key check confirms stored credentials", %{
    conn: conn
  } do
    document = conn |> get("/scenes") |> html_response(200) |> LazyHTML.from_fragment()
    assert Enum.empty?(LazyHTML.query(document, "#scene-direction, #scene-generation-settings"))

    vault = Process.whereis(GeminiVault)
    :ok = :sys.suspend(vault)

    try do
      {:ok, view, _} = live(conn, "/scenes")
      assert has_element?(view, "#scenes-panel[aria-busy=true]")
      assert_setup_only(view)
      refute has_element?(view, "#scene-gemini-setup", "No Gemini API key is stored")

      :ok = :sys.resume(vault)
      complete(view)
      refute has_element?(view, "#scene-gemini-setup")
      assert has_element?(view, "#scene-direction-form")
      assert has_element?(view, "#scene-generation-settings")
    after
      :sys.resume(vault)
    end
  end

  test "refresh retains the direction draft while rechecking credentials",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)

    values = %{
      "subject" => "landscape",
      "setting" => "coast",
      "light" => "dawn",
      "palette" => "sea_glass"
    }

    view |> form("#scene-direction-form", direction: values) |> render_change()
    vault = Process.whereis(GeminiVault)
    :ok = :sys.suspend(vault)

    try do
      view |> element("#scenes-refresh") |> render_click()
      assert has_element?(view, "#scenes-panel[aria-busy=true]")
      assert has_element?(view, "#scene-credential-check-signal")
      refute has_element?(view, "#scene-gemini-setup")
      assert has_element?(view, "#scene-direction-subject option[value=landscape][selected]")
      assert has_element?(view, "#scene-prompt-preview summary", "Preview unsaved prompt")
      assert has_element?(view, "#scenes-refresh[aria-disabled=true]:not([disabled])")
      assert has_element?(view, "#scene-generate[disabled]")

      assert StageDesigner.get_state!(1, actor: @actor) == nil

      :ok = :sys.resume(vault)
      complete(view)
      refute has_element?(view, "#scene-credential-check-signal")
      assert has_element?(view, "#scenes-refresh[aria-disabled=false]")
      assert has_element?(view, "#scene-direction-subject option[value=landscape][selected]")
      assert has_element?(view, "#scene-direction-guidance", "Unsaved changes")
      assert has_element?(view, "#scene-prompt-preview summary", "Preview unsaved prompt")
      assert StageDesigner.get_state!(1, actor: @actor) == nil
    after
      :sys.resume(vault)
    end
  end

  test "rechecking credentials blocks an otherwise eligible clean direction after gallery loading",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    vault = Process.whereis(GeminiVault)
    :ok = :sys.suspend(vault)

    try do
      view |> element("#scenes-refresh") |> render_click()
      render(view)

      assert %{
               scenes: true,
               gemini_status: :rechecking,
               scene_data: %{eligible: true},
               scene_loading: false,
               scene_error: false,
               scene_request_pending: false,
               scene_preparing: false,
               scene_settings: %{error: ""},
               scene_direction: %{status: :ready, dirty: false, error: ""}
             } = :sys.get_state(view.pid).socket.assigns

      assert %{id: diagnostic_id} = :sys.get_state(view.pid).socket.assigns.gemini_diagnostic
      assert_enqueued(worker: Lovelace.ConnectionDiagnostics.Worker, args: %{id: diagnostic_id})
      render_click(view, "scenes:request", %{})
      render(view)
      assert_no_scene_confirmation(view)
      refute has_element?(view, "#scene-generation-modal")

      render_click(view, "scenes:confirm", %{})
      render(view)
      assert_no_generation_requested(nil)

      :ok = :sys.resume(vault)
      complete(view)
      assert has_element?(view, "#scene-generate:not([disabled])")
      assert_no_scene_confirmation(view)
      assert_no_generation_requested(nil)
    after
      :sys.resume(vault)
    end
  end

  test "a failed refresh credential check removes operational controls and preserves scenery", %{
    conn: conn,
    settings: settings
  } do
    digest = publish(settings, @now, PNG.image())
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
    assert has_element?(view, "#scene-generation-modal")
    state = StageDesigner.get_state!(1, actor: @actor)

    GeminiVault.fail(:unavailable)
    view |> element("#scenes-refresh") |> render_click()
    complete(view)
    assert_setup_only(view)
    assert has_element?(view, "#scene-gemini-setup", "key availability couldn’t be checked")
    assert has_element?(view, "#workspace-background img[src='#{Storage.url(digest)}']")

    render_click(view, "scenes:request", %{})
    complete(view)
    assert_no_scene_confirmation(view)
    render_click(view, "scenes:confirm", %{})
    complete(view)
    refute has_element?(view, "#scene-generation-modal")
    assert_no_generation_requested(state)
  end

  test "unavailable Gemini credentials are not presented as a missing key", %{conn: conn} do
    GeminiVault.fail(:unavailable)
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)

    assert has_element?(view, "#scene-gemini-setup", "key availability couldn’t be checked")
    assert has_element?(view, "#scene-gemini-setup a[href='/connections/gemini']")
    refute has_element?(view, "#scene-gemini-setup", "No Gemini API key is stored")
    assert_setup_only(view)
    assert StageDesigner.get_state!(1, actor: @actor) == nil

    GeminiVault.fail(:locked)
    view |> element("#scene-gemini-setup a") |> render_click()
    view |> element("#show-scenes") |> render_click()
    complete(view)
    assert has_element?(view, "#scene-gemini-setup", "keychain is locked or access was denied")
    refute has_element?(view, "#scene-gemini-setup", "No Gemini API key is stored")
    assert_setup_only(view)
  end

  test "invalid Gemini credentials keep the designer hidden", %{conn: conn} do
    assert :ok = GeminiVault.put("unused", "invalid key with spaces")
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)

    assert has_element?(view, "#scene-gemini-setup", "invalid format")
    assert_setup_only(view)
    assert StageDesigner.get_state!(1, actor: @actor) == nil
  end

  test "a missing Gemini key shows only setup before any generation", %{conn: conn} do
    assert :ok = GeminiVault.delete("unused")
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)

    assert has_element?(view, "#scene-gemini-setup", "No Gemini API key is stored")

    assert has_element?(
             view,
             "#scene-gemini-setup a[href='/connections/gemini']",
             "Set up Gemini"
           )

    assert_setup_only(view)
    assert StageDesigner.get_state!(1, actor: @actor) == nil
  end

  test "setup-only retains active and unknown request warnings after removing the key", %{
    conn: conn
  } do
    assert {:ok, :started} = SceneGeneration.manual()
    attempt = SceneGeneration.current()
    assert :ok = GeminiVault.delete("unused")
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)

    assert_setup_only(view)
    assert has_element?(view, "#scene-setup-generation-status", "queued locally")
    assert has_element?(view, "#scene-setup-generation-status", "charges may still apply")
    assert has_element?(view, "#scene-global-activity")

    {:ok, _} = Attempt.record(attempt, %{status: :submitting})
    assert :ok = Generation.perform(attempt.id, :submit)
    complete(view)
    view |> element("#scene-gemini-setup a") |> render_click()
    view |> element("#show-scenes") |> render_click()
    complete(view)

    assert_setup_only(view)
    assert has_element?(view, "#scene-setup-generation-status", "Generation outcome unconfirmed")

    assert has_element?(
             view,
             "#scene-setup-generation-status",
             "does not cancel an earlier request"
           )

    assert has_element?(view, "#scene-global-activity")
    assert SceneGeneration.current().status == :unknown
  end

  test "picker confirmation captures exact settings without changing startup defaults", %{
    conn: conn
  } do
    defaults = Models.defaults()
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    choices = %{model: "gemini-3-pro-image", aspect_ratio: "4:3", image_size: "2K"}
    view |> form("#scene-generation-settings", generation: choices) |> render_submit()
    complete(view)
    assert has_element?(view, "#scene-confirmation-settings", "gemini-3-pro-image")
    assert has_element?(view, "#scene-confirmation-settings", "4:3")
    assert has_element?(view, "#scene-confirmation-settings", "2K")
    assert has_element?(view, "#scene-generation-modal", "store=true")
    assert has_element?(view, "#scene-generation-modal", "deletion")
    assert StageDesigner.get_state!(1, actor: @actor) == nil
    view |> element("#scene-generation-confirm") |> render_click()
    complete(view)
    attempt = SceneGeneration.current()
    assert Map.take(attempt, Map.keys(choices)) == choices
    assert attempt.status == :queued
    assert Models.defaults() == defaults
    assert has_element?(view, "#scene-global-activity[href='/scenes']")
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#scene-global-activity")
  end

  test "unknown outcome requires its own warning and a separate generation confirmation", %{
    conn: conn
  } do
    assert {:ok, :started} = SceneGeneration.manual()
    attempt = SceneGeneration.current()
    {:ok, _} = Attempt.record(attempt, %{status: :submitting})
    assert :ok = Generation.perform(attempt.id, :submit)
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    assert has_element?(view, "#scene-generate[disabled]")
    view |> element("#scene-current-acknowledge-#{attempt.id}") |> render_click()
    assert has_element?(view, "#scene-acknowledgement-modal", "may still incur charges")
    view |> element("#scene-acknowledgement-cancel") |> render_click()
    assert SceneGeneration.current().status == :unknown
    view |> element("#scene-current-acknowledge-#{attempt.id}") |> render_click()
    view |> element("#scene-acknowledgement-confirm") |> render_click()
    complete(view)
    assert SceneGeneration.current().status == :abandoned
    assert has_element?(view, "#scene-generate:not([disabled])")
    refute has_element?(view, "#scene-generation-modal")
    refute has_element?(view, "#scene-global-activity")
    assert has_element?(view, "#scene-history-#{attempt.id}", "acknowledged")
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
    assert has_element?(view, "#scene-generation-modal")
    assert SceneGeneration.current().id == attempt.id
  end

  test "permanent attempt history pages are URL-backed and survive deep links", %{conn: conn} do
    for _ <- 1..21 do
      {:ok, attempt} =
        Attempt.create(
          Map.merge(Models.defaults(), %{
            prompt: "synthetic",
            source: :manual,
            reservation_version: 0
          })
        )

      {:ok, _} = Attempt.record(attempt, %{status: :failed})
    end

    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    assert has_element?(view, "#scene-attempts-older:not([disabled])")
    view |> element("#scene-attempts-older") |> render_click()
    assert_patch(view, "/scenes?attempt_page=2")
    complete(view)
    assert has_element?(view, "#scene-attempt-pagination", "Attempts page 2")
    assert length(:sys.get_state(view.pid).socket.assigns.scene_data.attempts) == 1
    {:ok, reloaded, _} = live(conn, "/scenes?attempt_page=2")
    complete(reloaded)
    assert has_element?(reloaded, "#scene-attempt-pagination", "Attempts page 2")
    assert StageDesigner.get_state!(1, actor: @actor) == nil
  end

  test "guided direction previews, saves and survives reload without generating", %{conn: conn} do
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    assert has_element?(view, "#scene-direction-form")
    assert has_element?(view, "#scene-prompt-preview summary", "View generation prompt")
    assert has_element?(view, "#scene-direction-prompt", Settings.get().prompt)
    assert has_element?(view, "#scene-direction-guidance", "Configured prompt in use")
    assert StageDesigner.get_state!(1, actor: @actor) == nil

    values = %{
      "subject" => "landscape",
      "setting" => "coast",
      "light" => "dawn",
      "palette" => "sea_glass"
    }

    view |> form("#scene-direction-form", direction: values) |> render_change()
    assert has_element?(view, "#scene-direction-guidance", "Unsaved changes")
    assert has_element?(view, "#scene-generate[disabled]")
    assert has_element?(view, "#scene-prompt-preview summary", "Preview unsaved prompt")
    prompt = :sys.get_state(view.pid).socket.assigns.scene_direction.prompt
    assert prompt != Settings.get().prompt

    view |> element("#scenes-refresh") |> render_click()
    complete(view)
    assert :sys.get_state(view.pid).socket.assigns.scene_direction.prompt == prompt
    assert has_element?(view, "#scene-direction-subject option[value=landscape][selected]")
    render_click(view, "scenes:request", %{})
    refute has_element?(view, "#scene-generation-modal")

    view |> form("#scene-direction-form", direction: values) |> render_submit()

    assert has_element?(
             view,
             "#scene-direction-notice",
             "Direction saved. No generation requested."
           )

    assert has_element?(view, "#scene-direction-save[disabled]")
    assert has_element?(view, "#scene-generate:not([disabled])")
    assert StageDesigner.get_state!(1, actor: @actor) == nil
    {:ok, reloaded, _} = live(conn, "/scenes")
    complete(reloaded)
    assert has_element?(reloaded, "#scene-direction-subject option[value=landscape][selected]")
    assert :sys.get_state(reloaded.pid).socket.assigns.scene_direction.prompt == prompt
    reloaded |> form("#scene-generation-settings") |> render_submit()
    complete(reloaded)
    assert has_element?(reloaded, "#scene-confirmation-prompt", prompt)
    assert StageDesigner.get_state!(1, actor: @actor) == nil
  end

  test "discard restores the exact active prompt and invalid direction cannot be saved", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    original = :sys.get_state(view.pid).socket.assigns.scene_direction.prompt

    values = %{
      "subject" => "abstract",
      "setting" => "forest",
      "light" => "moonlight",
      "palette" => "mist"
    }

    view |> form("#scene-direction-form", direction: values) |> render_change()
    view |> element("#scene-direction-discard") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns.scene_direction.prompt == original
    refute has_element?(view, "#scene-direction-discard")

    render_submit(view, "scenes:direction-save", %{
      "direction" => Map.put(values, "subject", "forged")
    })

    assert has_element?(view, "#scene-direction-error[role=alert]", "available options")
    assert StageDesigner.scene_direction!(actor: %{role: :local_owner}).saved? == false
    assert StageDesigner.get_state!(1, actor: @actor) == nil
  end

  test "a direction changed after cost confirmation refuses generation", %{conn: conn} do
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)

    StageDesigner.save_scene_direction!(
      %{subject: "abstract", setting: "forest", light: "moonlight", palette: "mist"},
      actor: %{role: :local_owner}
    )

    view |> element("#scene-generation-confirm") |> render_click()
    complete(view)
    assert has_element?(view, "#scenes-panel", "saved direction changed")
    assert StageDesigner.get_state!(1, actor: @actor) == nil
  end

  test "confirmed requests reserve once and surface safe failures without calling Google", %{
    conn: conn
  } do
    Phoenix.PubSub.subscribe(Lovelace.PubSub, "stage_designer")
    {:ok, view, _} = live(conn, "/")
    view |> element("#show-scenes") |> render_click()
    complete(view)
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
    view |> element("#scene-generation-confirm") |> render_click()
    complete(view)
    assert_receive {:stage_background, %{status: :queued}}, 1_000
    assert SceneGeneration.current().status == :queued
    assert has_element?(view, "#scene-generate[disabled]")
    # Remove the fake credential before explicit execution so it fails locally, without HTTP.
    assert :ok = GeminiVault.delete("unused")
    assert :ok = Generation.perform(SceneGeneration.current().id, :submit)
    assert_receive {:stage_background, %{status: :failed}}, 1_000
    assert :ok = GeminiVault.put("unused", "synthetic-scenes-key")
    complete(view)
    assert has_element?(view, "#scenes-panel", "generation failed")
    assert has_element?(view, "#scene-generate:not([disabled])")
    refute has_element?(view, "#scene-generation-availability")
    assert has_element?(view, "#scene-generate[aria-describedby=scene-settings-guidance]")
    refute has_element?(view, "#scene-generation-modal")
    state = StageDesigner.get_state!(1, actor: @actor)
    assert state.status == :failed
    render_click(view, "scenes:confirm", %{})
    complete(view)
    assert StageDesigner.get_state!(1, actor: @actor) == state

    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
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
    complete(view)
    assert has_element?(view, "#scene-#{latest}[data-active=true]", "Current")
    assert has_element?(view, "#scene-preview-#{first}[phx-hook=StageBackground]")
    assert has_element?(view, "#scene-#{first} time", "2026-01-01 12:00 UTC")
    view |> element("#use-scene-#{first}") |> render_click()
    complete(view)
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
    complete(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    refute has_element?(view, "#scene-generation-availability")
    refute has_element?(view, "#scenes-panel", "Next eligible")
    refute has_element?(view, ".scene-status", "Recent scenery is ready")
    refute has_element?(view, ".scene-status", "No generation is currently confirmed")
    assert has_element?(view, ".scene-status time")
    assert has_element?(view, ".scene-status", "Last attempt:")
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
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
    complete(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    assert has_element?(view, "#use-scene-#{digest}[disabled]")
    assert has_element?(view, "#scene-#{digest}", "Local image unavailable")
    refute has_element?(view, "#scene-preview-#{digest}")
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
    assert has_element?(view, "#scene-generation-modal")
    view |> element("#scene-generation-cancel") |> render_click()
    assert StageDesigner.get_state!(1, actor: @actor) == state
    render_click(view, "scenes:select", %{"digest" => String.duplicate("a", 64)})
    complete(view)
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
    complete(view)
    assert has_element?(view, "#scene-generate[disabled]")

    assert has_element?(
             view,
             "#scene-generation-availability",
             "New requests are blocked to avoid overlap."
           )

    render_click(view, "scenes:request", %{})
    refute has_element?(view, "#scene-generation-modal")
    render_click(view, "scenes:confirm", %{})
    complete(view)
    assert_same_persisted_state(reserved)
    view |> element("#scenes-refresh") |> render_click()
    complete(view)
    assert has_element?(view, "#scene-generate[disabled]")
    assert_same_persisted_state(reserved)

    failed = StageDesigner.fail_state!(reserved, %{}, actor: @actor)

    Phoenix.PubSub.broadcast(Lovelace.PubSub, "stage_designer", {
      :stage_background,
      StageDesigner.background!()
    })

    complete(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    assert has_element?(view, "#scenes-panel", "generation failed")
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
    complete(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    assert has_element?(view, "#scenes-panel", "generation failed")
    view |> element("#scenes-refresh") |> render_click()
    complete(view)
    assert StageDesigner.get_state!(1, actor: @actor) == failed
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#home-overview")
    refute has_element?(view, "#scenes-panel")
    view |> element("#show-workspaces") |> render_click()
    view |> element("#show-connections") |> render_click()
    view |> element("#show-scenes") |> render_click()
    complete(view)
    assert has_element?(view, "#scene-generate:not([disabled])")
    refute has_element?(view, "#scene-generation-modal")
    assert StageDesigner.get_state!(1, actor: @actor) == failed
    {:ok, reloaded, _} = live(conn, "/")
    reloaded |> element("#show-scenes") |> render_click()
    complete(reloaded)
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
    complete(view)
    assert has_element?(view, "#scenes-panel[data-page='1']")
    assert has_element?(view, "#scene-pagination", "Page 1")
    assert length(:sys.get_state(view.pid).socket.assigns.scene_data.scenes) == 20
    refute has_element?(view, "#scene-#{oldest}")
    view |> element("#scenes-older") |> render_click()
    complete(view)
    assert has_element?(view, "#scenes-panel[data-page='2']")
    assert length(:sys.get_state(view.pid).socket.assigns.scene_data.scenes) == 3
    assert has_element?(view, "#scenes-older[disabled]")
    assert has_element?(view, "#use-scene-#{oldest}:not([disabled])")
    view |> element("#use-scene-#{oldest}") |> render_click()
    complete(view)
    assert has_element?(view, "#scene-#{oldest}[data-active=true]", "Current")
    assert has_element?(view, "#workspace-background img[src='#{Storage.url(oldest)}']")
    view |> element("#scenes-newer") |> render_click()
    complete(view)
    assert has_element?(view, "#scenes-panel[data-page='1']")
    assert has_element?(view, "#scenes-newer[disabled]")
    assert StageDesigner.background!().url == Storage.url(oldest)
  end

  defp assert_no_scene_confirmation(view) do
    assert %{
             scene_preparing: false,
             scene_prepared: nil,
             scene_confirmation: false,
             scene_confirmation_prompt: nil,
             scene_request_pending: false
           } = :sys.get_state(view.pid).socket.assigns
  end

  defp assert_no_generation_requested(expected_state) do
    assert StageDesigner.get_state!(1, actor: @actor) == expected_state
    assert {:ok, []} = Attempt.page(1)
    assert all_enqueued(worker: GenerationWorker) == []
  end

  defp assert_setup_only(view) do
    assert has_element?(view, "#scenes-panel > #scene-gemini-setup")
    refute has_element?(view, "#scenes-refresh")

    refute has_element?(
             view,
             "#scene-direction, #scene-direction-form, .scene-toolbar, " <>
               "#scene-generation-settings, #scenes-empty, #scene-gallery, #scene-pagination, " <>
               "#scene-attempt-history, #scene-generation-modal, #scene-acknowledgement-modal"
           )
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
