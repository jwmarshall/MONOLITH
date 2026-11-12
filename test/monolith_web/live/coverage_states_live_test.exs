defmodule MonolithWeb.CoverageStatesLiveTest do
  use MonolithWeb.ConnCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite
  import Phoenix.LiveViewTest
  import Monolith.TestSupport.BackgroundWork, only: [complete: 1]

  alias Monolith.{Calendar, Mail, Repo, StageDesigner, Workspaces}
  alias Monolith.Integrations.Google.ClientCredentials
  alias Monolith.StageDesigner.{Attempt, GenerationWorker, Settings}
  alias Monolith.TestSupport.{GeminiVault, OnboardingKeychain, PNG, SceneGeneration}

  @owner %{role: :local_owner}
  @service %{role: :stage_designer}

  defmodule CalendarIO do
    @behaviour Monolith.Calendar.Provider
    def get(id), do: {:ok, "synthetic:" <> id}
    def refresh(token), do: {:ok, %{access_token: token}}

    @impl true
    def calendars(_token) do
      {:ok,
       %{
         calendars: [
           %{id: "primary", name: "Personal", selected: true},
           %{id: "shared", name: "Shared studio", selected: false}
         ],
         truncated: false
       }}
    end

    @impl true
    def events(_token, calendar, _from, _to) do
      day = Date.utc_today()

      {:ok,
       %{
         events: [
           %{
             id: "event-" <> calendar,
             title:
               if(calendar == "shared", do: "Studio rehearsal", else: "Personal appointment"),
             start: Date.to_iso8601(day),
             end: Date.to_iso8601(Date.add(day, 1)),
             all_day: true,
             url: "https://calendar.google.com/calendar/event?eid=" <> calendar
           }
         ],
         truncated: false
       }}
    end
  end

  setup %{conn: conn} = tags do
    directory = Path.join(System.tmp_dir!(), "monolith-ui-states-#{Ash.UUID.generate()}")
    start_supervised!(GeminiVault)
    put_env(:gemini_vault, GeminiVault)
    put_env(:stage_designer, %Settings{enabled: false, storage_dir: directory})
    :ok = GeminiVault.put("unused", "synthetic-ui-states-key")
    on_exit(fn -> File.rm_rf!(directory) end)

    if tags[:calendar] do
      start_supervised!(OnboardingKeychain)
      put_env(:google_client_keychain, OnboardingKeychain)
      put_env(:gmail_provider, CalendarIO)
      put_env(:gmail_vault, CalendarIO)
      put_env(:calendar_provider, CalendarIO)
      :ok = ClientCredentials.save("synthetic-ui-client", "synthetic-ui-secret")
    end

    %{conn: authenticate_owner(conn)}
  end

  test "a paused generation resumes only status tracking and retains its paid request", %{
    conn: conn
  } do
    assert {:ok, :started} = SceneGeneration.manual()
    original = SceneGeneration.current()

    {:ok, _} =
      Attempt.record(original, %{
        status: :tracking_paused,
        provider_id: "synthetic-existing-interaction",
        poll_count: 180,
        tracking_errors: 3,
        last_checked_at: DateTime.utc_now()
      })

    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    assert has_element?(view, "#scene-generate[disabled]")
    assert has_element?(view, "#scene-current-check-#{original.id}:not([disabled])")
    assert has_element?(view, "#scene-current-signal-#{original.id} .status-label")

    view |> element("#scene-current-check-#{original.id}") |> render_click()
    complete(view)

    resumed = SceneGeneration.current()
    assert resumed.id == original.id
    assert resumed.provider_id == "synthetic-existing-interaction"
    assert resumed.status == :rendering
    assert resumed.poll_count == 0
    assert resumed.tracking_errors == 0
    assert_enqueued(worker: GenerationWorker, args: %{id: original.id, operation: "poll"})
    assert length(all_enqueued(worker: GenerationWorker, args: %{operation: "submit"})) == 1
    assert {:ok, [_]} = Attempt.page(1)
    refute has_element?(view, "#scene-generation-modal")
    assert has_element?(view, "#scene-generate[disabled]")
  end

  test "failed remote cleanup can be retried without replacing the published scene", %{conn: conn} do
    assert {:ok, :started} = SceneGeneration.manual()
    Req.Test.expect(__MODULE__, &SceneGeneration.respond(&1, PNG.image()))
    completed = SceneGeneration.submit(__MODULE__)
    background = StageDesigner.background!()

    {:ok, _} =
      Attempt.record(completed, %{
        cleanup: :failed,
        cleanup_error: "Synthetic deletion unavailable"
      })

    Repo.delete_all(Oban.Job)
    refute_enqueued(worker: GenerationWorker)

    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    assert has_element?(view, "#scene-history-#{completed.id}", "Synthetic deletion unavailable")
    assert has_element?(view, "#workspace-background img[src='#{background.url}']")
    view |> element("#scene-current-cleanup-#{completed.id}") |> render_click()
    complete(view)

    assert_enqueued(worker: GenerationWorker, args: %{id: completed.id, operation: "cleanup"})
    refute_enqueued(worker: GenerationWorker, args: %{operation: "submit"})
    assert SceneGeneration.current().status == :completed
    assert SceneGeneration.current().digest == completed.digest
    assert StageDesigner.background!().url == background.url
    assert {:ok, [_]} = Attempt.page(1)
    refute has_element?(view, "#scene-generation-modal")
    assert has_element?(view, "#scene-#{completed.digest}[data-active=true]")

    :ok = GeminiVault.delete("unused")
    view |> element("#scenes-refresh") |> render_click()
    complete(view)
    assert has_element?(view, "#scene-setup-generation-status .connection-warning")
    refute has_element?(view, "#scene-current-cleanup-#{completed.id}")
    assert StageDesigner.background!().url == background.url
  end

  test "acknowledging a failed attempt clears its global warning but keeps the failure history",
       %{
         conn: conn
       } do
    assert {:ok, :started} = SceneGeneration.manual()

    {:ok, failed} =
      Attempt.record(SceneGeneration.current(), %{status: :failed, failure: "Synthetic failure"})

    state = StageDesigner.get_state!(1, actor: @service)
    StageDesigner.fail_state!(state, %{}, actor: @service)

    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    assert has_element?(view, "#scene-global-activity")
    view |> element("#scene-current-acknowledge-#{failed.id}") |> render_click()
    complete(view)

    acknowledged = SceneGeneration.current()
    assert acknowledged.status == :failed
    assert %DateTime{} = acknowledged.acknowledged_at
    assert acknowledged.failure == failed.failure
    assert has_element?(view, "#scene-history-#{failed.id}", "Synthetic failure")
    refute has_element?(view, "#scene-current-acknowledge-#{failed.id}")
    refute has_element?(view, "#scene-global-activity")
    refute has_element?(view, "#scene-acknowledgement-modal, #scene-generation-modal")
    assert {:ok, [_]} = Attempt.page(1)

    {:ok, reloaded, _} = live(conn, "/scenes")
    complete(reloaded)
    refute has_element?(reloaded, "#scene-global-activity")
    assert has_element?(reloaded, "#scene-history-#{failed.id}")
  end

  test "changing generation settings revokes confirmation and exposes recoverable field errors",
       %{
         conn: conn
       } do
    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
    assert has_element?(view, "#scene-generation-modal")

    render_change(view, "scenes:settings-change", %{
      "generation" => %{
        "model" => "unavailable-model",
        "aspect_ratio" => "4:3",
        "image_size" => "2K"
      }
    })

    refute has_element?(view, "#scene-generation-modal")
    assert has_element?(view, "#scene-settings-error[role=alert]")

    assert has_element?(
             view,
             "#scene-generation-model[aria-invalid=true][aria-describedby='scene-settings-guidance scene-settings-error']"
           )

    assert has_element?(view, "#scene-generation-model option[value=''][selected]")
    assert has_element?(view, "#scene-generate[disabled]")
    render_click(view, "scenes:confirm", %{})
    assert {:ok, []} = Attempt.page(1)

    choices = %{model: "gemini-3-pro-image", aspect_ratio: "4:3", image_size: "2K"}
    view |> form("#scene-generation-settings", generation: choices) |> render_change()
    refute has_element?(view, "#scene-settings-error")
    assert has_element?(view, "#scene-generation-model[aria-invalid=false]")
    assert has_element?(view, "#scene-generate:not([disabled])")
    render_click(view, "scenes:confirm", %{})
    assert {:ok, []} = Attempt.page(1)

    view |> form("#scene-generation-settings") |> render_submit()
    complete(view)
    view |> element("#scene-generation-confirm") |> render_click()
    complete(view)
    assert Map.take(SceneGeneration.current(), Map.keys(choices)) == choices
  end

  test "a legacy unknown submission requires acknowledgement before releasing the slot", %{
    conn: conn
  } do
    initial = StageDesigner.initialize_state!(%{}, actor: @service)

    reserved =
      StageDesigner.reserve_state!(initial, %{last_attempt_at: DateTime.utc_now()},
        actor: @service
      )

    {:ok, view, _} = live(conn, "/scenes")
    complete(view)
    view |> element("#scene-current-acknowledge-legacy") |> render_click()

    assert has_element?(
             view,
             "#scene-acknowledgement-modal[data-initial-focus='#scene-acknowledgement-cancel'][data-return-focus='#scene-current-acknowledge-legacy']"
           )

    view |> element("#scene-acknowledgement-cancel") |> render_click()
    assert StageDesigner.get_state!(1, actor: @service).version == reserved.version
    assert {:ok, []} = Attempt.page(1)
    assert has_element?(view, "#scene-generate[disabled]")

    view |> element("#scene-current-acknowledge-legacy") |> render_click()
    view |> element("#scene-acknowledgement-confirm") |> render_click()
    complete(view)
    assert {:ok, [attempt]} = Attempt.page(1)
    assert attempt.source == :legacy
    assert attempt.status == :abandoned
    assert %DateTime{} = attempt.acknowledged_at
    assert has_element?(view, "#scene-history-#{attempt.id}")
    assert has_element?(view, "#scene-generate:not([disabled])")
    refute has_element?(view, "#scene-generation-modal")
    assert all_enqueued(worker: GenerationWorker) == []
  end

  @tag :calendar
  test "shared calendar selection persists and replaces the agenda across navigation and reload",
       %{
         conn: conn
       } do
    account = account()
    workspace = Workspaces.create_workspace!("Shared calendar studio", actor: @owner)
    Mail.attach_account!(%{workspace_id: workspace.id, account_id: account.id}, actor: @owner)
    window = window()
    poll(account, window)
    {:ok, view, _} = live(conn, "/connections/calendar")
    render_hook(view, "calendar:day", window)
    complete(view)
    selection = "#calendar-connections-select-#{account.id}"
    assert has_element?(view, "#{selection} input[value=primary][checked]")
    refute has_element?(view, "#{selection} input[value=shared][checked]")

    view |> form(selection, calendar_ids: ["", "shared"]) |> render_submit()
    assert {:ok, selected} = snapshot(account, window)
    assert selected.explicit_selection
    assert selected.selected_ids == ["shared"]
    poll(account, window)
    send(view.pid, {:calendar_changed, account.id})
    assert has_element?(view, "#{selection} input[value=shared][checked]")
    refute has_element?(view, "#{selection} input[value=primary][checked]")

    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#calendar-agenda-account-#{account.id}", "Studio rehearsal")
    refute has_element?(view, "#calendar-agenda-account-#{account.id}", "Personal appointment")

    assert has_element?(
             view,
             "#calendar-agenda a[target=_blank][rel='noopener noreferrer'][referrerpolicy=no-referrer]"
           )

    view |> element("#show-workspaces") |> render_click()
    render_click(view, "open_workspace", %{"id" => workspace.id})
    assert has_element?(view, "#calendar-agenda-account-#{account.id}", "Studio rehearsal")

    {:ok, reloaded, _} = live(conn, "/connections/calendar")
    render_hook(reloaded, "calendar:day", window)
    complete(reloaded)
    assert has_element?(reloaded, "#{selection} input[value=shared][checked]")
    assert {:ok, persisted} = snapshot(account, window)
    assert persisted.selected_ids == ["shared"]
  end

  @tag :calendar
  test "an explicitly empty calendar selection offers a route to selection instead of claiming an empty day",
       %{
         conn: conn
       } do
    account = account()
    window = window()
    poll(account, window)
    {:ok, view, _} = live(conn, "/connections/calendar")
    render_hook(view, "calendar:day", window)
    complete(view)

    view
    |> form("#calendar-connections-select-#{account.id}", calendar_ids: [""])
    |> render_submit()

    poll(account, window)
    send(view.pid, {:calendar_changed, account.id})
    view |> element("#home-link") |> render_click()
    agenda = "#calendar-agenda-account-#{account.id}"
    refute has_element?(view, "#{agenda} .calendar-events")
    assert has_element?(view, "#{agenda} .calendar-message", "No calendars selected")
    refute has_element?(view, "#{agenda} .calendar-message", "No events today")
    view |> element("#{agenda} a[href='/connections/calendar']") |> render_click()
    assert_patch(view, "/connections/calendar")
    complete(view)
    refute has_element?(view, "#calendar-connections-select-#{account.id} input[checked]")
    assert {:ok, selected} = snapshot(account, window)
    assert selected.explicit_selection
    assert selected.selected_ids == []
  end

  defp account do
    Mail.save_connection!(
      %{
        id: Ash.UUID.generate(),
        subject: "ui-states-#{Ash.UUID.generate()}",
        email: "studio@example.test",
        generation: Ash.UUID.generate(),
        calendar_enabled: true
      },
      actor: @owner
    )
  end

  defp window do
    day = Date.utc_today()

    %{
      "from" => DateTime.new!(day, ~T[00:00:00]) |> DateTime.to_iso8601(),
      "to" => DateTime.new!(Date.add(day, 1), ~T[00:00:00]) |> DateTime.to_iso8601(),
      "date" => Date.to_iso8601(day),
      "timezone" => "UTC"
    }
  end

  defp snapshot(account, window) do
    Calendar.snapshot(account.id, window["from"], window["to"], window["date"], actor: @owner)
  end

  defp poll(account, window) do
    {:ok, %{revision: revision}} =
      Calendar.prepare(
        account.id,
        window["from"],
        window["to"],
        window["date"],
        window["timezone"],
        actor: @owner
      )

    assert {:ok, _} = Calendar.poll(account.id, account.generation, revision, actor: @owner)
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:monolith, key)
    Application.put_env(:monolith, key, value)

    on_exit(fn ->
      case previous do
        {:ok, original} -> Application.put_env(:monolith, key, original)
        :error -> Application.delete_env(:monolith, key)
      end
    end)
  end
end
