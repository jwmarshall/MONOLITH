defmodule MonolithWeb.SceneErrorStatesTest do
  use MonolithWeb.ConnCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite
  import Phoenix.LiveViewTest
  import Monolith.TestSupport.BackgroundWork, only: [complete: 1]

  alias Monolith.{Repo, StageDesigner}
  alias Monolith.StageDesigner.{Attempt, Generation, GenerationWorker, Settings, Storage}
  alias Monolith.TestSupport.{GeminiVault, PNG, SceneGeneration}

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}
  @direction %{subject: "landscape", setting: "coast", light: "dawn", palette: "sea_glass"}
  @moduletag capture_log: true

  setup %{conn: conn} do
    directory = Path.join(System.tmp_dir!(), "monolith-scene-errors-#{Ash.UUID.generate()}")
    settings = %Settings{enabled: false, storage_dir: directory}
    start_supervised!(GeminiVault)
    put_env(:gemini_vault, GeminiVault)
    put_env(:stage_designer, settings)
    :ok = GeminiVault.put("unused", "synthetic-scene-errors-key")
    on_exit(fn -> File.rm_rf!(directory) end)
    %{conn: authenticate_owner(conn), settings: settings}
  end

  test "a failed direction save retains the saved default and draft until an explicit retry", %{
    conn: conn,
    settings: settings
  } do
    digest = publish(settings, PNG.image())
    saved = StageDesigner.scene_direction!(actor: @owner)
    state = StageDesigner.get_state!(1, actor: @service)
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)

    reject_writes("BEFORE INSERT ON stage_designer_directions", fn ->
      view |> form("#scene-direction-form", direction: @direction) |> render_submit()

      assert has_element?(
               view,
               "#scene-direction-error[role=alert]",
               "previous default is unchanged"
             )

      assert has_element?(view, "#scene-direction-subject option[value=landscape][selected]")
      assert has_element?(view, "#scene-direction-guidance", "Unsaved changes")
      assert has_element?(view, "#scene-generate[disabled]")
      assert StageDesigner.scene_direction!(actor: @owner) == saved
      assert StageDesigner.get_state!(1, actor: @service) == state
      assert_background(view, digest)
      assert_no_attempts()
    end)

    view |> form("#scene-direction-form", direction: @direction) |> render_submit()
    assert has_element?(view, "#scene-direction-notice", "Direction saved")
    refute has_element?(view, "#scene-direction-error")
    assert StageDesigner.scene_direction!(actor: @owner).values == @direction
    assert has_element?(view, "#scene-generate:not([disabled])")
    assert_background(view, digest)
    assert_no_attempts()
  end

  test "an unreadable direction blocks requests until refresh can reload it", %{
    conn: conn,
    settings: settings
  } do
    digest = publish(settings, PNG.image())
    StageDesigner.save_scene_direction!(@direction, actor: @owner)
    state = StageDesigner.get_state!(1, actor: @service)

    view =
      without_table("stage_designer_directions", fn ->
        {:ok, view, _} = live(conn, "/scenes")
        complete(view)
        assert has_element?(view, "#scene-direction-guidance[role=alert]")
        refute has_element?(view, "#scene-direction-form")
        assert has_element?(view, "#scene-generate[disabled]")
        assert_background(view, digest)
        assert StageDesigner.get_state!(1, actor: @service) == state
        assert_no_attempts()
        view
      end)

    view |> element("#scenes-refresh") |> render_click()
    complete(view)
    assert has_element?(view, "#scene-direction-form")
    assert has_element?(view, "#scene-direction-subject option[value=landscape][selected]")
    assert has_element?(view, "#scene-generate:not([disabled])")
    refute has_element?(view, "#scene-direction-guidance[role=alert]")
    assert_no_attempts()
  end

  test "gallery read failure is not an empty gallery and refresh preserves the existing attempt",
       %{
         conn: conn,
         settings: settings
       } do
    digest = publish(settings, PNG.image())
    assert {:ok, :started} = SceneGeneration.manual()
    original = SceneGeneration.current()
    state = StageDesigner.get_state!(1, actor: @service)
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    assert has_element?(view, "#scene-history-#{original.id}")

    without_table("stage_designer_attempts", fn ->
      view |> element("#scenes-refresh") |> render_click()
      complete(view)
      assert has_element?(view, ".scene-status", "Scenes couldn’t be loaded")
      refute has_element?(view, "#scenes-empty, #scene-gallery, #scene-attempt-history")
      assert has_element?(view, "#scene-generate[disabled]")
      assert_background(view, digest)
      assert StageDesigner.get_state!(1, actor: @service) == state
    end)

    view |> element("#scenes-refresh") |> render_click()
    complete(view)
    assert has_element?(view, "#scene-history-#{original.id}")
    assert has_element?(view, "#scene-#{digest}[data-active=true]")
    assert SceneGeneration.current() == original
    assert {:ok, [_]} = Attempt.page(1)
    assert length(all_enqueued(worker: GenerationWorker, args: %{operation: "submit"})) == 1
    assert_background(view, digest)
  end

  test "failed confirmation preparation leaves the background unchanged and can be retried", %{
    conn: conn,
    settings: settings
  } do
    digest = publish(settings, PNG.image())
    state = StageDesigner.get_state!(1, actor: @service)
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)

    without_table("stage_designer_directions", fn ->
      view |> form("#scene-generation-settings") |> render_submit()
      complete(view)
      assert has_element?(view, ".scene-status", "Confirmation couldn’t be prepared")
      refute has_element?(view, "#scene-generation-modal")
      assert StageDesigner.get_state!(1, actor: @service) == state
      assert_background(view, digest)
      assert_no_attempts()
    end)

    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
    assert has_element?(view, "#scene-generation-modal")
    view |> element("#scene-generation-cancel") |> render_click()
    assert StageDesigner.get_state!(1, actor: @service) == state
    assert_no_attempts()
  end

  test "a competing request after selection invalidates an earlier paid confirmation", %{
    conn: conn,
    settings: settings
  } do
    first = publish(settings, PNG.image(4, 2))
    latest = publish(settings, PNG.image(5, 2))
    {:ok, view, _} = live(conn, "/scenes")
    {:ok, other, _} = live(conn, "/scenes")
    complete(view)
    complete(other)
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
    assert has_element?(view, "#scene-generation-modal")

    other |> element("#use-scene-#{first}") |> render_click()
    complete(other)
    complete(view)
    assert_background(view, first)
    other |> form("#scene-generation-settings") |> render_submit()
    complete(other)
    other |> element("#scene-generation-confirm") |> render_click()
    complete(other)
    complete(view)
    original = SceneGeneration.current()
    state = StageDesigner.get_state!(1, actor: @service)
    assert state.selected_digest == first
    assert state.history == [latest, first]

    view |> element("#scene-generation-confirm") |> render_click()
    complete(view)
    assert has_element?(view, ".scene-status", "confirmation is invalid or expired")
    refute has_element?(view, "#scene-generation-modal")
    assert StageDesigner.get_state!(1, actor: @service) == state
    assert_background(view, first)
    assert SceneGeneration.current() == original
    assert original.status == :queued
    assert has_element?(view, "#scene-generate[disabled]")
    assert has_element?(view, "#scene-history-#{original.id}")
    assert {:ok, [_]} = Attempt.page(1)
    assert length(all_enqueued(worker: GenerationWorker, args: %{operation: "submit"})) == 1
  end

  test "a reservation write failure does not claim generation started or replace the active scene",
       %{
         conn: conn,
         settings: settings
       } do
    digest = publish(settings, PNG.image())
    state = StageDesigner.get_state!(1, actor: @service)
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)

    reject_writes("BEFORE INSERT ON stage_designer_attempts", fn ->
      view |> element("#scene-generation-confirm") |> render_click()
      complete(view)
      assert has_element?(view, ".scene-status", "Generation could not be started")
      refute has_element?(view, "#scene-generation-modal")
      assert has_element?(view, "#scene-generate:not([disabled])")
      assert StageDesigner.get_state!(1, actor: @service) == state
      assert_background(view, digest)
      assert_no_attempts()
    end)
  end

  test "a failed recovery write preserves the paused paid job and does not schedule another request",
       %{
         conn: conn,
         settings: settings
       } do
    digest = publish(settings, PNG.image())
    assert {:ok, :started} = SceneGeneration.manual()

    {:ok, original} =
      Attempt.record(SceneGeneration.current(), %{
        status: :tracking_paused,
        provider_id: "synthetic-paused-paid-job",
        poll_count: 180,
        tracking_errors: 3
      })

    state = StageDesigner.get_state!(1, actor: @service)
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)

    reject_writes("BEFORE UPDATE ON stage_designer_attempts", fn ->
      view |> element("#scene-current-check-#{original.id}") |> render_click()
      complete(view)
      assert has_element?(view, ".scene-status", "Recovery could not be scheduled")
      assert has_element?(view, "#scene-history-#{original.id} [data-status=tracking_paused]")
      assert has_element?(view, "#scene-current-check-#{original.id}:not([disabled])")
      assert has_element?(view, "#scene-generate[disabled]")
      assert SceneGeneration.current() == original
      assert StageDesigner.get_state!(1, actor: @service) == state
      refute_enqueued(worker: GenerationWorker, args: %{operation: "poll"})
      assert length(all_enqueued(worker: GenerationWorker, args: %{operation: "submit"})) == 1
      assert_background(view, digest)
    end)
  end

  test "an acknowledgement write failure retains the unknown outcome and its blocked slot", %{
    conn: conn,
    settings: settings
  } do
    digest = publish(settings, PNG.image())
    assert {:ok, :started} = SceneGeneration.manual()

    {:ok, original} =
      Attempt.record(SceneGeneration.current(), %{
        status: :unknown,
        failure: "Synthetic interrupted submission; outcome unknown"
      })

    state = StageDesigner.get_state!(1, actor: @service)
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    view |> element("#scene-history-acknowledge-#{original.id}") |> render_click()

    assert has_element?(
             view,
             "#scene-acknowledgement-modal[data-return-focus='#scene-history-acknowledge-#{original.id}']"
           )

    reject_writes("BEFORE UPDATE ON stage_designer_attempts", fn ->
      view |> element("#scene-acknowledgement-confirm") |> render_click()
      complete(view)
      assert has_element?(view, ".scene-status", "could not be acknowledged")
      refute has_element?(view, "#scene-acknowledgement-modal")
      assert has_element?(view, "#scene-history-#{original.id}", original.failure)
      assert has_element?(view, "#scene-current-acknowledge-#{original.id}")
      assert has_element?(view, "#scene-generate[disabled]")
      assert SceneGeneration.current() == original
      assert StageDesigner.get_state!(1, actor: @service) == state
      assert {:ok, [_]} = Attempt.page(1)
      assert length(all_enqueued(worker: GenerationWorker, args: %{operation: "submit"})) == 1
      assert_background(view, digest)
    end)
  end

  test "startup image publication distinguishes pending provider deletion from confirmed deletion",
       %{
         conn: conn,
         settings: settings
       } do
    settings = %{settings | enabled: true}
    put_env(:stage_designer, settings)
    StageDesigner.save_startup_preference!(%{enabled: true}, actor: @owner)
    assert :started = Generation.startup(settings, DateTime.utc_now())
    Req.Test.expect(__MODULE__, &SceneGeneration.respond(&1, PNG.image()))
    completed = SceneGeneration.submit(__MODULE__)
    assert completed.cleanup == :pending
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    assert has_element?(view, "#scene-history-#{completed.id}", "Startup request")
    assert has_element?(view, "#scene-history-#{completed.id}", "deletion pending")
    assert_background(view, completed.digest)

    Req.Test.expect(__MODULE__, fn request ->
      assert request.method == "DELETE"
      assert List.last(request.path_info) == completed.provider_id
      Plug.Conn.send_resp(request, 204, "")
    end)

    assert :ok = Generation.perform(completed.id, :cleanup, SceneGeneration.options(__MODULE__))
    complete(view)
    assert has_element?(view, "#scene-history-#{completed.id}", "deletion confirmed")
    refute has_element?(view, "#scene-history-#{completed.id}", "deletion pending")
    assert SceneGeneration.current().cleanup == :completed
    assert SceneGeneration.current().digest == completed.digest
    assert {:ok, [_]} = Attempt.page(1)
    assert_background(view, completed.digest)
  end

  test "failed startup saves preserve the saved choice and allow the same choice to be retried",
       %{
         conn: conn,
         settings: settings
       } do
    digest = publish(settings, PNG.image())
    state = StageDesigner.get_state!(1, actor: @service)
    {:ok, view, _} = live(conn, "/settings")
    view |> form("#startup-preference", enabled: "true") |> render_submit()

    for {saved, draft} <- [{true, false}, {false, true}] do
      choice = form(view, "#startup-preference", enabled: to_string(draft))

      reject_writes("BEFORE INSERT ON stage_designer_startup_preferences", fn ->
        render_submit(choice)
        assert has_element?(view, "#settings-panel [role=alert]")
        assert has_element?(view, "#startup-preference button[type=submit]:not([disabled])")
        assert_startup_choice(view, saved)
        assert StageDesigner.get_state!(1, actor: @service) == state
        assert_background(view, digest)
        assert_no_attempts()
      end)

      render_submit(choice)
      refute has_element?(view, "#settings-panel [role=alert]")
      assert_startup_choice(view, draft)

      view |> element("#home-link") |> render_click()
      view |> element("#show-settings") |> render_click()
      assert_startup_choice(view, draft)
      {:ok, reloaded, _} = live(conn, "/settings")
      assert_startup_choice(reloaded, draft)
      assert StageDesigner.get_state!(1, actor: @service) == state
      assert_background(reloaded, digest)
      assert_no_attempts()

      # A later failed save must also clear a preceding success in this view.
      view |> form("#startup-preference", enabled: to_string(draft)) |> render_submit()
    end
  end

  test "an unreadable startup choice blocks the form but not credential management and recovers",
       %{
         conn: conn
       } do
    StageDesigner.save_startup_preference!(%{enabled: true}, actor: @owner)

    view =
      without_table("stage_designer_startup_preferences", fn ->
        {:ok, view, _} = live(conn, "/settings")
        assert has_element?(view, "#settings-panel [role=alert]")
        refute has_element?(view, "#startup-preference")

        render_click(view, "settings:startup", %{"enabled" => "false"})
        assert has_element?(view, "#settings-panel [role=alert]")

        render_patch(view, "/connections/gemini")
        complete(view)
        assert has_element?(view, "#gemini-remove-form button[type=submit]:not([disabled])")
        assert has_element?(view, "#gemini-key-form button[type=submit]:not([disabled])")
        view |> element("[phx-click='gemini:check']") |> render_click()
        complete(view)
        assert has_element?(view, "#gemini-remove-form")
        view
      end)

    view |> element("#gemini-generation-help a[href='/settings']") |> render_click()
    refute has_element?(view, "#settings-panel [role=alert]")
    assert_startup_choice(view, true)
    view |> form("#startup-preference", enabled: "false") |> render_submit()
    assert_startup_choice(view, false)
    assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    assert_no_attempts()
  end

  test "Gemini key checks stay available independently of saved startup choice and environment veto",
       %{conn: conn, settings: settings} do
    {:ok, view, _} = live(conn, "/settings")

    for {saved, environment} <- [{false, true}, {true, false}, {true, true}] do
      Application.put_env(:monolith, :stage_designer, %{settings | enabled: environment})
      render_patch(view, "/settings")
      view |> form("#startup-preference", enabled: to_string(saved)) |> render_submit()
      assert_startup_choice(view, saved)

      render_patch(view, "/connections/gemini")
      complete(view)
      assert has_element?(view, "#gemini-remove-form")

      # A keychain refresh must observe the current gates without authorizing work.
      view |> element("[phx-click='gemini:check']") |> render_click()
      complete(view)
      assert has_element?(view, "#gemini-remove-form button[type=submit]:not([disabled])")

      assert %{enabled: ^saved, environment_enabled: ^environment} =
               StageDesigner.startup_preference!(actor: @owner)

      assert %{enabled: ^saved} = StageDesigner.get_startup_preference!(1, actor: @service)
      assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
      assert_no_attempts()

      view |> element("#gemini-generation-help a[href='/settings']") |> render_click()
      assert_startup_choice(view, saved)
    end

    GeminiVault.fail(:locked)
    render_patch(view, "/connections/gemini")
    complete(view)
    refute has_element?(view, "#gemini-remove-form")
    assert has_element?(view, "#gemini-key-form button[type=submit]:not([disabled])")
    view |> element("#gemini-generation-help a[href='/settings']") |> render_click()
    assert_startup_choice(view, true)
    assert_no_attempts()
  end

  test "malformed and out-of-view startup events cannot overwrite either saved choice", %{
    conn: conn
  } do
    for saved <- [false, true] do
      StageDesigner.save_startup_preference!(%{enabled: saved}, actor: @owner)
      {:ok, view, _} = live(conn, "/settings")

      for params <- [
            %{},
            %{"enabled" => nil},
            %{"enabled" => !saved},
            %{"enabled" => "sometimes"},
            %{"enabled" => ["true", "false"]},
            %{"enabled" => %{"value" => to_string(!saved)}}
          ] do
        render_click(view, "settings:startup", params)
        assert_startup_choice(view, saved)
        refute has_element?(view, "#settings-panel [role=alert]")
      end

      for path <- ["/", "/connections", "/connections/gemini", "/scenes"] do
        render_patch(view, path)
        complete(view)
        render_click(view, "settings:startup", %{"enabled" => to_string(!saved)})
        assert %{enabled: ^saved} = StageDesigner.get_startup_preference!(1, actor: @service)
        assert_no_attempts()
      end

      render_patch(view, "/settings")
      assert_startup_choice(view, saved)
      assert {:ok, nil} = StageDesigner.get_state(1, actor: @service)
    end
  end

  defp assert_startup_choice(view, enabled) do
    assert %{enabled: ^enabled} = StageDesigner.get_startup_preference!(1, actor: @service)

    selector = "#startup-preference input[type=checkbox][checked]"

    if enabled,
      do: assert(has_element?(view, selector)),
      else: refute(has_element?(view, selector))
  end

  defp assert_background(view, digest) do
    assert has_element?(view, "#workspace-background img[src='#{Storage.url(digest)}']")
    assert StageDesigner.background!().url == Storage.url(digest)
  end

  defp assert_no_attempts do
    assert {:ok, []} = Attempt.page(1)
    refute_enqueued(worker: GenerationWorker)
  end

  defp publish(settings, bytes) do
    now = DateTime.utc_now()
    state = StageDesigner.initialize_state!(%{}, actor: @service)
    reserved = StageDesigner.reserve_state!(state, %{last_attempt_at: now}, actor: @service)
    {:ok, published} = Storage.store_and_publish(settings, bytes, reserved, now)
    hd(published.history)
  end

  defp reject_writes(clause, fun) do
    Repo.query!("""
    CREATE TEMP TRIGGER scene_ui_write_failure
    #{clause}
    BEGIN
      SELECT RAISE(ABORT, 'synthetic scene UI write failure');
    END
    """)

    try do
      fun.()
    after
      Repo.query!("DROP TRIGGER scene_ui_write_failure")
    end
  end

  defp without_table(table, fun) do
    # Transactional SQLite DDL stays inside this test's shared sandbox connection.
    Repo.query!("ALTER TABLE #{table} RENAME TO scene_ui_unavailable_table")

    try do
      fun.()
    after
      Repo.query!("ALTER TABLE scene_ui_unavailable_table RENAME TO #{table}")
    end
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:monolith, key)
    Application.put_env(:monolith, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:monolith, key, value)
        :error -> Application.delete_env(:monolith, key)
      end
    end)
  end
end
