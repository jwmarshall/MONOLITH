defmodule LovelaceWeb.SceneComponents do
  @moduledoc "Recent app-wide scenery and explicit, potentially billable requests."
  use LovelaceWeb, :html

  alias Lovelace.StageDesigner.{DirectionOptions, Models}

  attr :background, :map, required: true

  def activity(assigns) do
    attempt = Map.get(assigns.background, :attempt)
    status = assigns.background.status

    visible? =
      status in [:queued, :submitting, :rendering, :tracking_paused, :failed, :uncertain] &&
        !(status == :failed && attempt && Map.get(attempt, :acknowledged_at))

    assigns = assign(assigns, visible: visible?, status: status)

    ~H"""
    <.link
      :if={@visible}
      id="scene-global-activity"
      patch="/scenes"
      class="scene-global-activity"
      aria-label={status_text(@status) <> " Open Scenes."}
    >
      <.status_signal
        id="scene-global-signal"
        state={signal_state(@status)}
        label={status_text(@status)}
        embedded
      />
    </.link>
    """
  end

  attr :data, :map, default: nil
  attr :loading, :boolean, required: true
  attr :error, :boolean, required: true
  attr :pending, :boolean, required: true
  attr :notice, :string, required: true
  attr :confirmation, :boolean, required: true
  attr :confirmation_prompt, :string, default: nil
  attr :direction, :map, required: true
  attr :settings, :map, required: true
  attr :preparing, :boolean, default: false
  attr :prepared, :map, default: nil
  attr :acknowledgement, :map, default: nil

  def gallery(assigns) do
    assigns =
      assign(
        assigns,
        :direction_ready,
        match?(%{status: :ready, dirty: false, error: ""}, assigns.direction)
      )

    assigns = assign(assigns, :attempt, if(assigns.data, do: Map.get(assigns.data, :attempt)))

    ~H"""
    <section
      id="scenes-panel"
      class="scenes-panel"
      aria-label="Saved scenes"
      aria-busy={to_string(@loading)}
      data-page={@data && @data.page}
    >
      <.direction_editor direction={@direction} />
      <div class="scene-toolbar">
        <div
          class="scene-status connection-card"
          role="status"
          aria-live="polite"
          aria-label="Scene generation status"
        >
          <.status_signal
            :if={@loading}
            id="scene-loading-signal"
            state={:active}
            label="Loading scene status…"
          />
          <p :if={@error}>
            Scenes couldn’t be loaded. Refresh status to retry. No generation was requested.
          </p>
          <p :if={@notice != ""}>{@notice}</p>
          <p :if={@data && !@error && !@attempt && @data.status not in [:ready, :idle]}>
            <.status_signal
              id="scene-attempt-signal"
              state={signal_state(@data.status)}
              label={status_text(@data.status)}
              text
            />
          </p>
          <.attempt
            :if={@attempt && !@error}
            attempt={@attempt}
            origin="current"
            loading={@loading}
          />
          <p :if={@data && Map.get(@data, :last_attempt_at) && !@attempt}>
            Last attempt: <.timestamp value={@data.last_attempt_at} />
          </p>
          <button
            :if={@data && @data.status == :uncertain && !@attempt && !@error}
            id="scene-current-acknowledge-legacy"
            type="button"
            class="workspace-action"
            phx-click="scenes:acknowledge"
            phx-value-id="legacy"
            phx-value-origin="current"
            disabled={@loading}
          >Acknowledge unknown outcome…</button>
          <p :if={@data && !@data.eligible} id="scene-generation-availability">
            New requests are blocked to avoid overlap. Check a paused job’s status, or review an
            unknown outcome before acknowledging it. Refresh status only reads local state.
          </p>
        </div>
        <div class="mail-actions">
          <button
            id="scenes-refresh"
            type="button"
            class="workspace-action"
            phx-click="scenes:refresh"
            disabled={@loading}
          >Refresh status</button>
        </div>
      </div>
      <.generation_settings
        settings={@settings}
        disabled={
          @pending || @preparing || @loading || @error || !@data || !@data.eligible ||
            !@direction_ready
        }
        guidance={
          cond do
            @data && !@data.eligible -> "scene-generation-availability"
            !@direction_ready -> "scene-direction-guidance"
            true -> "scene-settings-guidance"
          end
        }
      />
      <p :if={@data && @data.scenes == [] && !@error} id="scenes-empty" class="home-empty">
        No generated scenes yet. Bundled scenery remains available.
      </p>
      <ul :if={@data && !@error && @data.scenes != []} id="scene-gallery" class="scene-gallery">
        <li
          :for={
            {scene, index} <- Enum.with_index(@data.scenes, (@data.page - 1) * @data.page_size + 1)
          }
          id={"scene-#{scene.digest}"}
          class="scene-card"
          data-active={to_string(scene.active)}
        >
          <div class="scene-preview">
            <span class="scene-preview-fallback">Preview unavailable</span>
            <img
              :if={scene.available}
              id={"scene-preview-#{scene.digest}"}
              src={scene.url}
              alt={"Generated scenery #{index}"}
              phx-hook="StageBackground"
              data-loaded="false"
            />
          </div>
          <div class="scene-caption">
            <div>
              <h3>Scene {index}<span :if={scene.active} class="scene-current"> · Current</span></h3>
              <p class="mail-muted">
                <.timestamp :if={scene.generated_at} value={scene.generated_at} /><span :if={
                  !scene.generated_at
                }>Generation date unavailable</span>
              </p>
              <p :if={!scene.available} class="connection-warning">Local image unavailable</p>
            </div>
            <button
              id={"use-scene-#{scene.digest}"}
              type="button"
              class="workspace-action"
              phx-click="scenes:select"
              phx-value-digest={scene.digest}
              disabled={scene.active || !scene.available}
              aria-label={"Use scene #{index} as background"}
            >
              {if scene.active, do: "In use", else: "Use scene"}
            </button>
          </div>
        </li>
      </ul>
      <nav
        :if={@data && !@error && (@data.has_previous || @data.has_next)}
        id="scene-pagination"
        class="scene-pagination"
        aria-label="Scene gallery pages"
      >
        <button
          id="scenes-newer"
          type="button"
          class="workspace-action"
          phx-click="scenes:page"
          phx-value-direction="newer"
          disabled={@loading || !@data.has_previous}
        >Newer scenes</button>
        <span class="mail-muted" role="status">Page {@data.page}</span>
        <button
          id="scenes-older"
          type="button"
          class="workspace-action"
          phx-click="scenes:page"
          phx-value-direction="older"
          disabled={@loading || !@data.has_next}
        >Older scenes</button>
      </nav>
      <.attempt_history :if={@data && !@error} data={@data} loading={@loading} />
      <LovelaceWeb.ModalComponents.modal
        :if={@confirmation && @prepared}
        id="scene-generation-modal"
        title="Generate a new scene?"
        on_cancel="scenes:cancel"
        initial_focus="#scene-generation-cancel"
        return_focus="#scene-generate"
      >
        <p class="scene-confirmation-copy">
          Google Gemini may incur API charges, even if this request fails or its outcome is unknown.
          Only generic art direction is sent, never mail or workspace content.
          No automatic retries or manual daily cooldown. A successful image replaces the current scenery;
          otherwise it stays unchanged.
        </p>
        <dl id="scene-confirmation-settings" class="scene-request-settings">
          <div>
            <dt>Model</dt><dd>{model_label(@prepared.model)} ({@prepared.model})</dd>
          </div>
          <div>
            <dt>Aspect ratio</dt><dd>{@prepared.aspect_ratio}</dd>
          </div>
          <div>
            <dt>Image size</dt><dd>{@prepared.image_size}</dd>
          </div>
        </dl>
        <p class="scene-confirmation-copy">
          This request uses Google’s background generation with <code>store=true</code>.
          Google stores the job and result so LOVELACE can track it. After saving the image locally,
          LOVELACE requests deletion from Google. Deletion can fail; its status is retained in
          attempt history. This is not a promise of zero provider retention.
        </p>
        <details
          id="scene-confirmation-prompt"
          class="scene-prompt connection-help"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>Prompt for this request</summary>
          <p>{@confirmation_prompt}</p>
        </details>
        <div class="workspace-editor-actions">
          <button
            id="scene-generation-confirm"
            type="button"
            class="workspace-action workspace-action-primary"
            phx-click="scenes:confirm"
            phx-disable-with="Requesting…"
          >Generate · may incur charges</button>
          <button
            id="scene-generation-cancel"
            type="button"
            class="workspace-action"
            phx-click="scenes:cancel"
          >Cancel</button>
        </div>
      </LovelaceWeb.ModalComponents.modal>
      <LovelaceWeb.ModalComponents.modal
        :if={@acknowledgement}
        id="scene-acknowledgement-modal"
        title="Acknowledge an unknown outcome?"
        on_cancel="scenes:acknowledge-cancel"
        initial_focus="#scene-acknowledgement-cancel"
        return_focus={@acknowledgement.return_focus}
      >
        <p class="scene-confirmation-copy">
          Google may still be running this request and it may still incur charges.
          Acknowledging does not cancel it or confirm that it failed. LOVELACE will abandon
          tracking and release the generation slot, while retaining this attempt in history.
          A later generation is a separate, potentially billable request and requires a new confirmation.
        </p>
        <div class="workspace-editor-actions">
          <button
            id="scene-acknowledgement-confirm"
            type="button"
            class="workspace-action"
            phx-click="scenes:acknowledge-confirm"
            phx-disable-with="Acknowledging…"
          >Acknowledge and release slot</button>
          <button
            id="scene-acknowledgement-cancel"
            type="button"
            class="workspace-action"
            phx-click="scenes:acknowledge-cancel"
          >Keep tracking state</button>
        </div>
      </LovelaceWeb.ModalComponents.modal>
    </section>
    """
  end

  attr :direction, :map, required: true

  def direction_editor(assigns) do
    assigns = assign(assigns, :fields, DirectionOptions.fields())

    ~H"""
    <section id="scene-direction" class="scene-direction" aria-labelledby="scene-direction-title">
      <div class="scene-direction-heading">
        <div>
          <h3 id="scene-direction-title">Scene direction</h3>
          <p class="mail-muted">Choose the subject, light and atmosphere.</p>
        </div>
        <span :if={@direction.status == :ready} class="scene-direction-scope mail-muted">
          Default for new scenes
        </span>
      </div>
      <p :if={@direction.status == :loading} id="scene-direction-guidance" role="status">
        Loading your direction…
      </p>
      <p :if={@direction.status == :error} id="scene-direction-guidance" role="alert">
        Your scene direction couldn’t be loaded. Refresh status to retry before generating.
      </p>
      <.form
        :if={@direction.status == :ready}
        for={@direction.form}
        id="scene-direction-form"
        phx-change="scenes:direction-change"
        phx-submit="scenes:direction-save"
      >
        <div class="scene-direction-fields">
          <div :for={field <- @fields} class="scene-direction-field">
            <label for={"scene-direction-#{field.key}"}>{field.label}</label>
            <select
              id={"scene-direction-#{field.key}"}
              name={@direction.form[field.key].name}
              class="connection-workspace-select"
              aria-describedby={
                if @direction.error == "",
                  do: "scene-direction-guidance",
                  else: "scene-direction-guidance scene-direction-error"
              }
              aria-invalid={to_string(@direction.error != "")}
            >
              {Phoenix.HTML.Form.options_for_select(field.options, @direction.values[field.key])}
            </select>
          </div>
        </div>
        <div class="scene-direction-footer">
          <div class="mail-actions">
            <button
              id="scene-direction-save"
              type="submit"
              class="workspace-action workspace-action-primary"
              disabled={!@direction.dirty && @direction.saved.saved?}
              phx-disable-with="Saving…"
            >Save direction</button>
            <button
              :if={@direction.dirty}
              id="scene-direction-discard"
              type="button"
              class="workspace-action"
              phx-click="scenes:direction-discard"
            >Discard changes</button>
          </div>
          <p id="scene-direction-guidance" class="mail-muted">
            <%= cond do %>
              <% @direction.dirty -> %>
                Unsaved changes · Save before generating.
              <% !@direction.saved.saved? -> %>
                Configured prompt in use. Save to apply these choices.
              <% true -> %>
                Used for manual and opted-in startup scenes. Saving never generates.
            <% end %>
          </p>
        </div>
        <p
          :if={@direction.error != ""}
          id="scene-direction-error"
          class="connection-warning"
          role="alert"
        >
          {@direction.error}
        </p>
        <p :if={@direction.notice != ""} id="scene-direction-notice" class="mail-muted" role="status">
          {@direction.notice}
        </p>
        <details
          id="scene-prompt-preview"
          class="scene-prompt connection-help"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>
            {if @direction.dirty, do: "Preview unsaved prompt", else: "View generation prompt"}
          </summary>
          <p id="scene-direction-prompt">{@direction.prompt}</p>
        </details>
      </.form>
    </section>
    """
  end

  attr :settings, :map, required: true
  attr :disabled, :boolean, required: true
  attr :guidance, :string, required: true

  def generation_settings(assigns) do
    assigns =
      assign(assigns, :fields, [
        {:model, "Model", Models.options()},
        {:aspect_ratio, "Aspect ratio", Enum.map(Models.ratios(), &{&1, &1})},
        {:image_size, "Image size", Enum.map(Models.sizes(), &{&1, &1})}
      ])

    ~H"""
    <.form
      for={@settings.form}
      id="scene-generation-settings"
      class="scene-generation-settings"
      phx-change="scenes:settings-change"
      phx-submit="scenes:request"
    >
      <fieldset>
        <legend>Generate a scene</legend>
        <p id="scene-settings-guidance" class="mail-muted">
          Settings for this manual request only. Startup defaults are unchanged.
        </p>
        <div class="scene-generation-fields">
          <div :for={{key, label, options} <- @fields} class="scene-direction-field">
            <label for={"scene-generation-#{key}"}>{label}</label>
            <select
              id={"scene-generation-#{key}"}
              name={@settings.form[key].name}
              class="connection-workspace-select"
              aria-describedby={
                if @settings.error == "",
                  do: "scene-settings-guidance",
                  else: "scene-settings-guidance scene-settings-error"
              }
              aria-invalid={to_string(@settings.error != "")}
            >
              <option
                :if={!Enum.any?(options, fn {_, value} -> value == @settings.values[key] end)}
                value=""
                selected
              >
                Choose an available option
              </option>
              {Phoenix.HTML.Form.options_for_select(options, @settings.values[key])}
            </select>
          </div>
        </div>
        <p
          :if={@settings.error != ""}
          id="scene-settings-error"
          class="connection-warning"
          role="alert"
        >
          {@settings.error}
        </p>
        <button
          id="scene-generate"
          type="submit"
          class="workspace-action workspace-action-primary"
          aria-describedby={@guidance}
          disabled={@disabled || @settings.error != ""}
        >
          <span class="inline-flex" aria-hidden="true"><.icon name="hero-sparkles" class="size-4" /></span>
          Generate scene
        </button>
      </fieldset>
    </.form>
    """
  end

  attr :data, :map, required: true
  attr :loading, :boolean, required: true

  def attempt_history(assigns) do
    assigns =
      assign(assigns,
        attempts: Map.get(assigns.data, :attempts, []),
        page: Map.get(assigns.data, :attempt_page, 1),
        has_next: Map.get(assigns.data, :attempts_has_next, false),
        has_previous: Map.get(assigns.data, :attempts_has_previous, false)
      )

    ~H"""
    <section
      id="scene-attempt-history"
      class="scene-attempt-history"
      aria-labelledby="scene-attempt-history-title"
    >
      <h3 id="scene-attempt-history-title">Generation attempts</h3>
      <p :if={@attempts == []} class="mail-muted">No recorded attempts on this page.</p>
      <ul :if={@attempts != []} class="scene-attempt-list">
        <li :for={attempt <- @attempts} id={"scene-history-#{attempt.id}"}>
          <.attempt attempt={attempt} origin="history" loading={@loading} />
        </li>
      </ul>
      <nav
        :if={@has_previous || @has_next}
        id="scene-attempt-pagination"
        class="scene-pagination"
        aria-label="Generation attempt pages"
      >
        <button
          id="scene-attempts-newer"
          type="button"
          class="workspace-action"
          phx-click="scenes:attempt-page"
          phx-value-direction="newer"
          disabled={@loading || !@has_previous}
        >Newer attempts</button>
        <span class="mail-muted" role="status">Attempts page {@page}</span>
        <button
          id="scene-attempts-older"
          type="button"
          class="workspace-action"
          phx-click="scenes:attempt-page"
          phx-value-direction="older"
          disabled={@loading || !@has_next}
        >Older attempts</button>
      </nav>
    </section>
    """
  end

  attr :attempt, :map, required: true
  attr :origin, :string, required: true, values: ["current", "history"]
  attr :loading, :boolean, required: true

  def attempt(assigns) do
    ~H"""
    <div class="scene-attempt" data-status={@attempt.status}>
      <p>
        <.status_signal
          id={"scene-#{@origin}-signal-#{@attempt.id}"}
          state={signal_state(@attempt.status)}
          label={status_text(@attempt.status)}
          text
        />
      </p>
      <p class="mail-muted scene-attempt-settings">
        {model_label(Map.get(@attempt, :model))}
        <span :if={Map.get(@attempt, :aspect_ratio)}> · {@attempt.aspect_ratio}</span>
        <span :if={Map.get(@attempt, :image_size)}> · {@attempt.image_size}</span>
        <span :if={Map.get(@attempt, :source)}> · {source_text(@attempt.source)}</span>
      </p>
      <p :if={Map.get(@attempt, :inserted_at)} class="mail-muted">
        Requested: <.timestamp value={@attempt.inserted_at} />
      </p>
      <p :if={Map.get(@attempt, :last_checked_at)} class="mail-muted">
        Last job check: <.timestamp value={@attempt.last_checked_at} />
      </p>
      <p :if={Map.get(@attempt, :completed_at)} class="mail-muted">
        Finished locally: <.timestamp value={@attempt.completed_at} />
      </p>
      <p :if={Map.get(@attempt, :failure)} class="connection-warning">{@attempt.failure}</p>
      <p :if={Map.get(@attempt, :cleanup) in [:pending, :completed, :failed]} class="mail-muted">
        {cleanup_text(@attempt.cleanup)}
      </p>
      <p :if={Map.get(@attempt, :cleanup_error)} class="connection-warning">
        {@attempt.cleanup_error}
      </p>
      <p :if={Map.get(@attempt, :acknowledged_at)} class="mail-muted">
        Acknowledged: <.timestamp value={@attempt.acknowledged_at} />
      </p>
      <div class="mail-actions">
        <button
          :if={@attempt.status in [:tracking_paused, :rendering]}
          id={"scene-#{@origin}-check-#{@attempt.id}"}
          type="button"
          class="workspace-action"
          phx-click="scenes:check"
          phx-value-id={@attempt.id}
          disabled={@loading}
        >Check job status · no generation</button>
        <button
          :if={@attempt.status == :completed && Map.get(@attempt, :cleanup) == :failed}
          id={"scene-#{@origin}-cleanup-#{@attempt.id}"}
          type="button"
          class="workspace-action"
          phx-click="scenes:check"
          phx-value-id={@attempt.id}
          disabled={@loading}
        >Retry Google deletion · no generation</button>
        <button
          :if={@attempt.status in [:unknown, :failed] && !Map.get(@attempt, :acknowledged_at)}
          id={"scene-#{@origin}-acknowledge-#{@attempt.id}"}
          type="button"
          class="workspace-action"
          phx-click="scenes:acknowledge"
          phx-value-id={@attempt.id}
          phx-value-origin={@origin}
          disabled={@loading}
        >{if @attempt.status == :unknown,
          do: "Acknowledge unknown outcome…",
          else: "Acknowledge failure"}</button>
      </div>
    </div>
    """
  end

  attr :value, :any, required: true

  def timestamp(assigns) do
    assigns = assign(assigns, :date, parse_date(assigns.value))

    ~H"""
    <time :if={@date} datetime={DateTime.to_iso8601(@date)}>{Calendar.strftime(
      @date,
      "%Y-%m-%d %H:%M UTC"
    )}</time>
    <span :if={!@date}>Date unavailable</span>
    """
  end

  defp parse_date(%DateTime{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp model_label(nil), do: "Model unavailable"

  defp model_label(model),
    do:
      Enum.find_value(Models.options(), model, fn {label, value} ->
        if value == model, do: label
      end)

  defp source_text(:manual), do: "Manual request"
  defp source_text(:startup), do: "Startup request"
  defp source_text(:operator), do: "Operator request"
  defp source_text(:legacy), do: "Legacy request"
  defp source_text(_), do: "Request source unavailable"

  defp cleanup_text(:pending), do: "Google job deletion pending after local save."
  defp cleanup_text(:completed), do: "Google job deletion confirmed after local save."
  defp cleanup_text(:failed), do: "Google job deletion failed; provider retention may continue."

  defp signal_state(status) when status in [:submitting, :rendering], do: :active
  defp signal_state(status) when status in [:queued, :tracking_paused], do: :waiting
  defp signal_state(status) when status in [:unknown, :uncertain, :abandoned], do: :unknown
  defp signal_state(status) when status in [:completed, :ready], do: :ready
  defp signal_state(:idle), do: :waiting
  defp signal_state(_), do: :warning

  defp status_text(:queued), do: "Scene generation queued locally."
  defp status_text(:submitting), do: "Submitting the scene request to Google."
  defp status_text(:rendering), do: "Google is rendering the scene."

  defp status_text(:tracking_paused),
    do: "Scene tracking paused. Google may still be working; check the known job’s status."

  defp status_text(status) when status in [:uncertain, :unknown],
    do: "Generation outcome unconfirmed. It may still be running or have been interrupted."

  defp status_text(:abandoned),
    do: "Unknown outcome acknowledged; tracking abandoned. This did not cancel Google’s work."

  defp status_text(:completed), do: "Scene saved locally."
  defp status_text(:ready), do: "Scene ready."
  defp status_text(:idle), do: "No generation in progress."

  defp status_text(:failed),
    do: "Scene generation failed. No new scenery was published for this attempt."

  defp status_text(:unavailable),
    do: "Scene state is unavailable. Refresh status before requesting a generation."

  defp status_text(_), do: "No generation is currently confirmed."
end
