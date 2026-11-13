defmodule MonolithWeb.GeminiComponents do
  @moduledoc "App-wide Gemini credentials, never attached to a mailbox or workspace."
  use MonolithWeb, :html

  attr :status, :atom, required: true
  attr :startup_preference, :map, default: nil

  def connection(assigns) do
    assigns =
      assign(
        assigns,
        :startup_enabled,
        assigns.startup_preference && assigns.startup_preference.enabled &&
          assigns.startup_preference.environment_enabled
      )

    ~H"""
    <section
      id="gemini-connection"
      class="connection-card provider-credential"
      aria-labelledby="gemini-heading"
    >
      <div class="provider-credential-body">
        <header class="card-section-heading">
          <p class="mail-eyebrow">Scenery</p>
          <h3 id="gemini-heading" class="empty-state-title">
            Gemini API key
          </h3>
          <p id="gemini-status" class="mail-muted" role="status">
            <.status_signal
              id="gemini-credential-signal"
              state={signal_state(@status)}
              label={status_text(@status)}
            />
          </p>
        </header>
        <p :if={@status in [:locked, :unavailable]} class="connection-warning">
          Unlock the dedicated MONOLITH keychain with your MONOLITH password.
          This does not use the macOS login keychain. Install or update the native helper
          with <code>mix monolith.keychain.build</code>; see <code>docs/GMAIL.md</code>
          before changing an existing helper’s access permissions.
        </p>
        <div class="empty-state-actions gemini-actions">
          <MonolithWeb.ModalComponents.credential_modal
            id="gemini-key-editor"
            title="Gemini API key"
            trigger={if @status == :stored, do: "Replace API key", else: "Add API key"}
            primary={@status != :stored}
            form_id="gemini-key-form"
            action="/connections/gemini"
            initial_focus="#gemini-api-key"
            save="Save API key"
          >
            <input type="hidden" name="operation" value="save" />
            <label for="gemini-api-key">Gemini API key</label>
            <input
              id="gemini-api-key"
              name="api_key"
              type="password"
              class="workspace-name-input"
              required
              maxlength="4096"
              autocomplete="off"
              spellcheck="false"
              autocapitalize="none"
              aria-describedby="gemini-key-hint"
            />
            <p id="gemini-key-hint" class="mail-muted">
              Enter a Gemini Developer API key. The stored value is never displayed again.
            </p>
          </MonolithWeb.ModalComponents.credential_modal>
          <button
            type="button"
            class="workspace-action"
            phx-click="gemini:check"
            disabled={@status in [:loading, :rechecking]}
            aria-describedby="gemini-status"
          >
            Check Keychain
          </button>
          <.form
            :if={@status in [:stored, :invalid]}
            for={%{}}
            id="gemini-remove-form"
            action="/connections/gemini"
            method="post"
          >
            <input type="hidden" name="operation" value="remove" />
            <button
              type="submit"
              class="workspace-action workspace-action-danger"
              data-confirm="Remove the Gemini key from this device? Existing scenery stays. A request already in progress cannot be cancelled."
            >
              Remove API key
            </button>
          </.form>
        </div>
        <p class="empty-state-copy">
          <%= cond do %>
            <% is_nil(@startup_preference) -> %>
              Startup preference could not be read. Check Settings before relying on automatic generation.
            <% @startup_enabled -> %>
              Startup generation is enabled. Eligible restarts may incur API charges.
            <% !@startup_preference.environment_enabled -> %>
              Startup generation is blocked by the environment, regardless of the saved preference.
            <% true -> %>
              Startup generation is off in your saved preferences.
          <% end %>
          Saving a key does not generate an image or verify Google access.
        </p>
        <p class="provider-safety">
          Generation may incur Google API charges. Only generic art direction is sent;
          no mail is shared. Background requests allow Google to store the interaction.
          MONOLITH requests deletion after local publication, but failed cleanup or
          unresolved requests may leave it subject to Google’s retention policy.
          Removing a key keeps existing scenery and cooldowns and cannot cancel a request
          already in progress.
        </p>
      </div>
    </section>
    """
  end

  defp signal_state(status) when status in [:loading, :rechecking], do: :active
  defp signal_state(:stored), do: :ready
  defp signal_state(:unknown), do: :unknown
  defp signal_state(:not_connected), do: :offline
  defp signal_state(_), do: :warning

  defp status_text(:stored), do: "API key stored · Google access not verified"
  defp status_text(:not_connected), do: "No API key stored"
  defp status_text(:locked), do: "Keychain is locked or access was denied"
  defp status_text(:invalid), do: "Stored key has an invalid format · replace or remove it"
  defp status_text(:loading), do: "Checking Keychain…"
  defp status_text(:rechecking), do: "Rechecking Keychain…"
  defp status_text(:unknown), do: "Keychain not checked"
  defp status_text(_), do: "Keychain unavailable · credential state unknown"
end
