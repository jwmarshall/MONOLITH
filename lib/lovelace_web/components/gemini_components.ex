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
          <p class="mail-eyebrow">App-wide · Scenery</p>
          <h3 id="gemini-heading">Google Gemini</h3>
          <p id="gemini-status" class="mail-muted" role="status">{status_text(@status)}</p>
        </div>
      </div>
      <p class="mail-muted">
        {if @enabled,
          do: "Startup generation is enabled.",
          else:
            "Startup generation is disabled. Enable LOVELACE_STAGE_ENABLED in your local settings and restart to opt in."} Eligible restarts may incur API charges. Saving a key does not generate an image or verify Google access.
      </p>
      <p :if={@status in [:locked, :unavailable]} class="connection-warning">
        Check the macOS login keychain and this item’s access. Rebuilding the helper can
        invalidate existing Gmail approvals; do not rebuild as an access repair.
        Build with <code>mix lovelace.keychain.build</code> only when installing or updating
        the native helper. See <code>docs/GMAIL.md</code> for partition-access recovery.
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
              Stored in the macOS Keychain on this device, not in workspace data. Use a Gemini Developer API key from Google AI Studio.
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
      <p class="mail-muted gemini-safety">
        Scenery is shared across LOVELACE, not added to workspaces. Only generic art direction is sent; no mail is shared.
        Generation remains startup-only with a persisted minimum 24-hour cooldown and no automatic retries.
        Removing a key keeps existing scenery and cooldowns; it cannot cancel a request already in progress.
      </p>
    </section>
    """
  end

  defp status_text(:stored), do: "API key stored · Google access not verified"
  defp status_text(:not_connected), do: "No API key stored"
  defp status_text(:locked), do: "Keychain is locked or access was denied"
  defp status_text(:invalid), do: "Stored key has an invalid format · replace or remove it"
  defp status_text(:loading), do: "Checking Keychain…"
  defp status_text(:unknown), do: "Keychain not checked"
  defp status_text(_), do: "Keychain unavailable · credential state unknown"
end
