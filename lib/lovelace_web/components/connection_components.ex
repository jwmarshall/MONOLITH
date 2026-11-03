defmodule LovelaceWeb.ConnectionComponents do
  @moduledoc "Global connection directory; provider health belongs to each management page."
  use LovelaceWeb, :html

  def overview(assigns) do
    ~H"""
    <nav id="connections-overview" class="connections-overview" aria-label="Connections">
      <.link id="open-connection-gmail" patch="/connections/gmail" class="connection-provider">
        <.icon name="hero-envelope" class="size-6" />
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Gmail</span>
          <span class="mail-muted">Read-only mail accounts</span>
        </span>
        <.icon name="hero-arrow-up-right" class="size-5" />
      </.link>
      <.link id="open-connection-calendar" patch="/connections/calendar" class="connection-provider">
        <.icon name="hero-calendar-days" class="size-6" />
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Calendar</span>
          <span class="mail-muted">Optional read-only agendas</span>
        </span>
        <.icon name="hero-arrow-up-right" class="size-5" />
      </.link>
      <.link id="open-connection-gemini" patch="/connections/gemini" class="connection-provider">
        <.icon name="hero-sparkles" class="size-6" />
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Gemini</span>
          <span class="mail-muted">App-wide scenery credentials</span>
        </span>
        <.icon name="hero-arrow-up-right" class="size-5" />
      </.link>
    </nav>
    """
  end
end
