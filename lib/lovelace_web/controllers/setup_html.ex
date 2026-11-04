defmodule LovelaceWeb.SetupHTML do
  use LovelaceWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.stage id="setup-stage" class="stage-static" static>
      <main id="main-content" class="workspace-glass owner-glass" aria-labelledby="setup-heading">
        <section class="setup-content">
          <p class="home-eyebrow">LOVELACE · First setup</p>
          <h1 id="setup-heading">
            {if @paired?, do: "Protect your workspace", else: "Pair this browser"}
          </h1>
          <p :if={@error} id="setup-error" class="connection-warning" role="alert">{@error}</p>
          <p :if={@interrupted?} role="status">
            Setup was interrupted. Continue with the original password. Existing files and keys will not be replaced.
          </p>
          <form
            :if={!@paired?}
            id="setup-pair-form"
            action="/setup/pair"
            method="post"
            class="owner-unlock-form"
          >
            <p>
              Enter the one-time pairing code shown in the terminal that started LOVELACE. This prevents another browser from claiming your installation.
            </p>
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <label for="setup-pairing-code">Terminal pairing code</label>
            <input
              id="setup-pairing-code"
              name="pairing_code"
              type="password"
              autocomplete="off"
              required
              maxlength="43"
              class="owner-password"
              spellcheck="false"
            />
            <p class="mail-muted">
              Codes expire after 15 minutes and can be used once. Restart the server for a new code; your setup files are preserved.
            </p>
            <button type="submit" class="owner-submit">Continue securely</button>
          </form>
          <form
            :if={@paired?}
            id="setup-password-form"
            action="/setup/password"
            method="post"
            class="owner-unlock-form"
          >
            <p>
              Your password unlocks a dedicated macOS keychain and encrypted local database. Google accounts are connected separately.
            </p>
            <p id="setup-recovery-warning">
              <strong>There is no password reset or recovery.</strong>
              If you forget this password, you permanently lose access to your encrypted data. Save it in your password manager.
            </p>
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <label for="setup-password">{if @interrupted?,
              do: "Original password",
              else: "New password"}</label>
            <input
              id="setup-password"
              name="password"
              type="password"
              autocomplete="new-password"
              required
              minlength="12"
              maxlength="1024"
              aria-describedby="setup-password-hint setup-recovery-warning"
              class="owner-password"
            />
            <p id="setup-password-hint" class="mail-muted">
              At least 12 characters; at most 1024 UTF-8 bytes.
            </p>
            <label for="setup-password-confirmation">Confirm password</label>
            <input
              id="setup-password-confirmation"
              name="password_confirmation"
              type="password"
              autocomplete="new-password"
              required
              minlength="12"
              maxlength="1024"
              class="owner-password"
            />
            <label class="setup-acknowledgement" for="setup-acknowledge">
              <input
                id="setup-acknowledge"
                name="acknowledge_recovery"
                type="checkbox"
                value="true"
                required
              />
              <span>I understand that my password cannot be recovered.</span>
            </label>
            <p class="mail-muted">
              Creating the vault may take up to two minutes. If macOS requests authorization for the dedicated LOVELACE keychain, use this same password. Keep this page open until setup finishes.
            </p>
            <button type="submit" class="owner-submit">{if @interrupted?,
              do: "Resume encrypted setup",
              else: "Create encrypted workspace"}</button>
          </form>
        </section>
      </main>
    </Layouts.stage>
    """
  end
end
