defmodule LovelaceWeb.StatusComponents do
  @moduledoc "Custom, last-known status signals; motion means confirmed activity, never progress."
  use Phoenix.Component

  attr :id, :string, required: true

  attr :state, :atom,
    required: true,
    values: [:active, :ready, :unknown, :waiting, :warning, :offline]

  attr :label, :string, required: true
  attr :text, :boolean, default: false
  attr :embedded, :boolean, default: false

  def status_signal(assigns) do
    ~H"""
    <span
      id={@id}
      class={["status-signal", @text && "status-signal-text"]}
      data-state={@state}
      data-embedded={to_string(@embedded)}
      phx-hook="StatusSignal"
      tabindex={if !@text && !@embedded, do: "0"}
      role={if !@text, do: "img"}
      aria-label={if !@text, do: @label}
    >
      <svg
        class="status-glyph"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
        focusable="false"
      >
        <circle :if={@state != :warning} class="status-ring" cx="12" cy="12" r="8" />
        <path :if={@state == :active} class="status-orbit" d="M12 4a8 8 0 0 1 8 8" />
        <path :if={@state == :ready} d="m8.5 12 2.3 2.3 4.7-4.7" />
        <path :if={@state == :unknown} d="M10 12h4" />
        <path :if={@state == :waiting} d="M10 9v6m4-6v6" />
        <path :if={@state == :offline} d="m6.5 17.5 11-11" />
        <path :if={@state == :warning} d="m12 3 10 18H2L12 3Zm0 6v5m0 3h.01" />
      </svg>
      <span :if={@text} class="status-label">{@label}</span>
      <span :if={!@text} class="status-tooltip" aria-hidden="true">{@label}</span>
    </span>
    """
  end
end
