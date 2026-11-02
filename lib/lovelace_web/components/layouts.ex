defmodule LovelaceWeb.Layouts do
  @moduledoc """
  Document and workspace layouts shared by LOVELACE's web interface.
  """
  use LovelaceWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div id="workspace" class="glass-workspace">
      <a href="#workspace-pane" class="workspace-skip-link">Skip to workspace</a>
      <div id="workspace-background" class="workspace-background" aria-hidden="true"></div>

      <main id="main-content" class="workspace-glass" aria-labelledby="workspace-title">
        <p id="workspace-instructions" class="sr-only">
          Click or focus the workspace to bring the glass into focus. Press Escape to look
          through to the landscape. Workspace features are not connected yet.
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
          phx-window-keydown={
            JS.set_attribute({"aria-pressed", "false"})
            |> JS.dispatch("lovelace:brand-reset", to: "#workspace-brand")
          }
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
    JS.set_attribute({"aria-pressed", "true"})
    |> JS.dispatch("lovelace:brand-focus", to: "#workspace-brand")
  end

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
