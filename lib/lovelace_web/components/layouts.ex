defmodule LovelaceWeb.Layouts do
  @moduledoc """
  Document and workspace layouts shared by LOVELACE's web interface.
  """
  use LovelaceWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :background, :map, default: %{url: nil, status: :unavailable}
  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> assign(:background_url, local_background_url(assigns.background))
      |> assign(:idle_minutes, Application.get_env(:lovelace, :workspace_idle_minutes, 3))

    ~H"""
    <div
      id="workspace"
      class="glass-workspace"
      phx-hook="WorkspaceIdle"
      data-idle-minutes={@idle_minutes}
      data-workspace-focus={focus_workspace()}
      data-workspace-reset={reset_workspace()}
    >
      <a href="#workspace-pane" class="workspace-skip-link">Skip to workspace</a>
      <div id="workspace-background" class="workspace-background" aria-hidden="true">
        <img
          :if={@background_url}
          id={"stage-background-#{Path.rootname(Path.basename(@background_url))}"}
          class="workspace-background-image"
          src={@background_url}
          alt=""
          phx-hook="StageBackground"
        />
      </div>
      <p id="stage-background-status" class="sr-only" role="status" aria-live="polite">
        {background_status(@background)}
      </p>

      <main id="main-content" class="workspace-glass" aria-labelledby="workspace-title">
        <p id="workspace-instructions" class="sr-only">
          Click or focus the workspace to bring the glass into focus. Press Escape to look
          through to the landscape. After inactivity, the landscape returns; click or type to
          resume. Workspace features are not connected yet.
        </p>
        <button
          id="workspace-pane"
          type="button"
          class="workspace-pane"
          aria-label="Focus workspace"
          aria-describedby="workspace-instructions"
          aria-pressed="false"
          phx-click={focus_workspace()}
          phx-focus={focus_workspace()}
          phx-window-keydown={reset_workspace()}
          phx-key="Escape"
        >
          <span class="sr-only">Focus workspace</span>
        </button>
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp focus_workspace do
    JS.set_attribute({"aria-pressed", "true"}, to: "#workspace-pane")
    |> JS.dispatch("lovelace:brand-focus", to: "#workspace-brand")
  end

  defp reset_workspace do
    JS.set_attribute({"aria-pressed", "false"}, to: "#workspace-pane")
    |> JS.dispatch("lovelace:brand-reset", to: "#workspace-brand")
  end

  defp local_background_url(%{url: url}) when is_binary(url) do
    if Regex.match?(~r/\A\/stage\/background\/[0-9a-f]{64}\.(?:png|jpg)\z/, url), do: url
  end

  defp local_background_url(_background), do: nil

  defp background_status(%{status: status}) when status in [:pending, :generating] do
    "Preparing the background. The current landscape remains available."
  end

  defp background_status(%{status: status}) when status in [:failed, :error, :unavailable] do
    "Background unavailable. Using the previous image or original landscape."
  end

  defp background_status(_background), do: ""

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection interrupted")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
