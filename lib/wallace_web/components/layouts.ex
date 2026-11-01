defmodule WallaceWeb.Layouts do
  @moduledoc """
  Document and workspace layouts shared by Wallace's web interface.
  """
  use WallaceWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a
      href="#main-content"
      class="sr-only focus:not-sr-only focus:absolute focus:p-4 focus:bg-base-200"
    >
      Skip to content
    </a>
    <header class="border-b border-base-300 px-6 py-7 lg:px-12">
      <div class="mx-auto flex max-w-7xl items-center justify-between gap-6">
        <.link navigate={~p"/"} class="text-sm font-medium uppercase tracking-[0.4em]">
          Wallace
        </.link>
        <span class="text-xs uppercase tracking-[0.2em] text-stone-400">Private workspace</span>
      </div>
    </header>

    <main id="main-content" class="mx-auto max-w-7xl px-6 py-16 lg:px-12 lg:py-24">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
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
