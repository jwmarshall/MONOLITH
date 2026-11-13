defmodule MonolithWeb.GoogleComponents do
  @moduledoc "Shared Google Desktop OAuth client settings; account consent stays separate."
  use MonolithWeb, :html

  attr :status, :atom, required: true

  def connection(assigns) do
    ~H"""
    <section
      id="google-connection"
      class="connection-card provider-credential"
      aria-labelledby="google-heading"
    >
      <div class="provider-credential-body">
        <header class="card-section-heading">
          <p class="mail-eyebrow">Gmail &amp; Calendar</p>
          <h3 id="google-heading" class="empty-state-title">
            Google Desktop client
          </h3>
          <p id="google-status" class="mail-muted" role="status">
            <.status_signal
              id="google-credential-signal"
              state={signal_state(@status)}
              label={status_text(@status)}
            />
          </p>
        </header>
        <div class="empty-state-actions gemini-actions">
          <MonolithWeb.ModalComponents.credential_modal
            id="google-client-editor"
            title="Google Desktop client"
            trigger={
              if @status == :stored, do: "Replace client settings", else: "Add client settings"
            }
            primary={@status != :stored}
            form_id="google-client-form"
            action="/connections/google"
            initial_focus="#google-client-id"
            save="Save client settings"
          >
            <label for="google-client-id">Client ID</label>
            <input
              id="google-client-id"
              name="client_id"
              type="password"
              class="workspace-name-input"
              required
              maxlength="8192"
              autocomplete="off"
              spellcheck="false"
              autocapitalize="none"
              aria-describedby="google-client-hint"
            />
            <label for="google-client-secret">Client secret</label>
            <input
              id="google-client-secret"
              name="client_secret"
              type="password"
              class="workspace-name-input"
              required
              maxlength="8192"
              autocomplete="off"
              spellcheck="false"
              autocapitalize="none"
              aria-describedby="google-client-hint"
            />
            <p id="google-client-hint" class="mail-muted">
              Both values are required. Stored values are never displayed again.
            </p>
          </MonolithWeb.ModalComponents.credential_modal>
          <button
            type="button"
            class="workspace-action"
            phx-click="google:check"
            disabled={@status == :loading}
            aria-describedby="google-status"
          >
            Check Keychain
          </button>
        </div>
        <p :if={@status == :stored} class="empty-state-copy">
          Next, connect an account in
          <.link patch="/connections/gmail" class="workspace-action-link">Gmail</.link>
          and optionally enable <.link patch="/connections/calendar" class="workspace-action-link">Calendar</.link>.
        </p>
      </div>
    </section>
    """
  end

  defp signal_state(:loading), do: :active
  defp signal_state(:stored), do: :ready
  defp signal_state(:unknown), do: :unknown
  defp signal_state(:not_connected), do: :offline
  defp signal_state(_), do: :warning

  defp status_text(:stored), do: "Client settings stored · Google access not verified"
  defp status_text(:not_connected), do: "No client settings stored"
  defp status_text(:locked), do: "Keychain is locked or access was denied"
  defp status_text(:invalid), do: "Stored settings have an invalid format · replace them"
  defp status_text(:loading), do: "Checking Keychain…"
  defp status_text(:unknown), do: "Keychain not checked"
  defp status_text(_), do: "Keychain unavailable · credential state unknown"
end
