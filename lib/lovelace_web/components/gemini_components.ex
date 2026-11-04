defmodule LovelaceWeb.GeminiComponents do
  @moduledoc "App-wide Gemini credentials, never attached to a mailbox or workspace."
  use LovelaceWeb, :html
  alias Lovelace.StageDesigner.Settings

  attr :status, :atom, required: true

  def connection(assigns) do
    assigns = assign(assigns, :enabled, Settings.get().enabled)

    ~H"""
    <section
      id="gemini-connection"
      class="connection-card gemini-connection"
      aria-labelledby="gemini-heading"
    >
      <div class="connection-identity">
        <.icon name="hero-sparkles" class="integration-icon size-6" />
        <div class="mail-account-identity">
          <p class="mail-eyebrow">Scenery</p>
          <h3 id="gemini-heading">Google Gemini</h3>
          <p id="gemini-status" class="mail-muted" role="status">
            <.status_signal
              id="gemini-credential-signal"
              state={signal_state(@status)}
              label={status_text(@status)}
              text={@status in [:not_connected, :locked, :invalid, :unavailable]}
            />
          </p>
        </div>
      </div>
      <p class="mail-muted">
        {if @enabled,
          do: "Startup generation is enabled. Eligible restarts may incur API charges.",
          else: "Startup generation is disabled."} Saving a key does not generate an image or verify Google access.
      </p>
      <p :if={@status in [:locked, :unavailable]} class="connection-warning">
        Unlock the dedicated LOVELACE keychain with your LOVELACE password.
        This does not use the macOS login keychain. Install or update the native helper
        with <code>mix lovelace.keychain.build</code>; see <code>docs/GMAIL.md</code>
        before changing an existing helper’s access permissions.
      </p>
      <div class="mail-actions gemini-actions">
        <button
          type="button"
          class="workspace-action"
          phx-click="gemini:check"
          disabled={@status == :loading}
        >
          Check Keychain
        </button>
        <details
          id="gemini-key-editor"
          class="gemini-key-editor"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary class="workspace-action">
            {if @status == :stored, do: "Replace API key", else: "Add API key"}
          </summary>
          <.form
            for={%{}}
            id="gemini-key-form"
            action="/connections/gemini"
            method="post"
            class="gemini-key-form"
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
              Use a Gemini Developer API key from Google AI Studio. Stored in this device’s macOS Keychain.
            </p>
            <button type="submit" class="workspace-action workspace-action-primary">Save API key</button>
          </.form>
        </details>
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
            class="workspace-action"
            data-confirm="Remove the Gemini key from this device? Existing scenery stays. A request already in progress cannot be cancelled."
          >
            Remove API key
          </button>
        </.form>
      </div>
      <details
        id="gemini-generation-help"
        class="connection-help gemini-safety mail-muted"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Scenery &amp; billing</summary>
        <p>
          Scenery is app-wide. Only generic art direction is sent to Google; no mail is shared.
          Request images in Scenes with cost confirmation, or opt into startup generation with
          <code>LOVELACE_STAGE_ENABLED=true</code>
          in local settings and restart.
        </p>
        <p>
          Each request may incur API charges. Manual requests have no daily cooldown;
          automatic startup has a persisted 24-hour minimum. No automatic retries.
        </p>
        <p>
          Removing a key keeps scenery and cooldowns, and cannot cancel an in-progress request.
        </p>
      </details>
    </section>
    """
  end

  defp signal_state(:loading), do: :active
  defp signal_state(:stored), do: :ready
  defp signal_state(:unknown), do: :unknown
  defp signal_state(:not_connected), do: :offline
  defp signal_state(_), do: :warning

  defp status_text(:stored), do: "API key stored · Google access not verified"
  defp status_text(:not_connected), do: "No API key stored"
  defp status_text(:locked), do: "Keychain is locked or access was denied"
  defp status_text(:invalid), do: "Stored key has an invalid format · replace or remove it"
  defp status_text(:loading), do: "Checking Keychain…"
  defp status_text(:unknown), do: "Keychain not checked"
  defp status_text(_), do: "Keychain unavailable · credential state unknown"
end
