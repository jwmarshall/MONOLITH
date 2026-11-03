defmodule LovelaceWeb.SceneComponents do
  @moduledoc "Recent app-wide scenery and explicit, potentially billable requests."
  use LovelaceWeb, :html

  attr :data, :map, default: nil
  attr :loading, :boolean, required: true
  attr :error, :boolean, required: true
  attr :pending, :boolean, required: true
  attr :notice, :string, required: true
  attr :confirmation, :boolean, required: true

  def gallery(assigns) do
    ~H"""
    <section
      id="scenes-panel"
      class="scenes-panel"
      aria-label="Saved scenes"
      aria-busy={to_string(@loading)}
      data-page={@data && @data.page}
    >
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
          <p :if={@data && !@error && @data.status != :ready}>
            <.status_signal
              id="scene-attempt-signal"
              state={:warning}
              label={status_text(@data.status)}
              text
            />
          </p>
          <p :if={@data && @data.last_attempt_at}>
            Last attempt: <.timestamp value={@data.last_attempt_at} />
          </p>
          <p :if={@data && !@data.eligible} id="scene-generation-availability">
            New requests are blocked to avoid overlap. Refresh status after this attempt resolves.
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
          <button
            id="scene-generate"
            type="button"
            class="workspace-action workspace-action-primary"
            phx-click="scenes:request"
            aria-describedby={@data && !@data.eligible && "scene-generation-availability"}
            disabled={@pending || @loading || @error || !@data || !@data.eligible}
          >
            <span class="inline-flex" aria-hidden="true"><.icon name="hero-sparkles" class="size-4" /></span>
            Generate scene
          </button>
        </div>
      </div>
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
              alt={"Generated architectural scene #{index}"}
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
      <LovelaceWeb.ModalComponents.modal
        :if={@confirmation}
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
    </section>
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

  defp status_text(:uncertain),
    do: "Generation outcome unconfirmed. It may still be running or have been interrupted."

  defp status_text(:failed),
    do:
      "The last generation failed. Existing scenery is unchanged. Check Gemini in Connections before retrying."

  defp status_text(:unavailable),
    do: "Scene state is unavailable. Refresh status before requesting a generation."

  defp status_text(_), do: "No generation is currently confirmed."
end
