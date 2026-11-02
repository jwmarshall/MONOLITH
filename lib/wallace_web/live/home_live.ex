defmodule WallaceWeb.HomeLive do
  @moduledoc """
  The glass workspace foundation. Product features are not connected yet.
  """
  use WallaceWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Workspace")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 id="workspace-title" class="sr-only">LOVELACE</h1>
      <div id="workspace-brand" class="workspace-brand" aria-hidden="true">
        <svg
          id="lovelace-monogram"
          class="workspace-monogram"
          viewBox="0 0 104 104"
          fill="none"
          xmlns="http://www.w3.org/2000/svg"
          aria-hidden="true"
          focusable="false"
        >
          <path
            d="M16 82C34 65 64 23 56 12C48 1 33 37 29 63C24 94 41 88 57 70C73 51 89 18 80 12C70 3 56 42 52 66C47 91 62 90 88 71"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
        <p class="workspace-wordmark">LOVELACE</p>
      </div>
    </Layouts.app>
    """
  end
end
