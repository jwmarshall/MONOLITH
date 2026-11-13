defmodule MonolithWeb.SetupHTML do
  use MonolithWeb, :html

  def show(assigns) do
    ~H"""
    <Layouts.stage
      id="setup-stage"
      class="stage-static"
      data-first-run-entrance={
        if !@paired? && !@interrupted? && is_nil(@error),
          do: "true",
          else: "false"
      }
      static
    >
      <a class="workspace-skip-link" href="#main-content">Skip to setup</a>
      <main
        id="main-content"
        class="workspace-glass owner-glass"
        aria-labelledby="setup-heading"
        tabindex="-1"
      >
        <section class="setup-content">
          <header class="owner-heading">
            <p class="onboarding-eyebrow">First run / Terminal pairing</p>
            <h1 id="setup-heading" tabindex="-1">
              {if @paired?, do: "Protect your workspace.", else: "Begin on this computer."}
            </h1>
            <p class="owner-supporting">
              {if @paired?,
                do:
                  "This browser is paired. Your owner password protects local data and credentials.",
                else: "Pair this browser before creating the local owner."}
            </p>
          </header>
          <div class="setup-plane">
            <div :if={@error} id="setup-error" class="onboarding-error" role="alert">
              <strong>This step couldn’t be completed.</strong>
              <p>{@error}</p>
              <a href={if @paired?, do: "#setup-password", else: "#setup-pairing-code"}>Return to the form</a>
            </div>
            <p :if={@interrupted?} class="onboarding-note" role="status">
              Setup was interrupted. Continue with the original password. Existing files and keys will not be replaced.
            </p>
            <form
              :if={!@paired?}
              id="setup-pair-form"
              action="/setup/pair"
              method="post"
              class="owner-unlock-form"
            >
              <header class="onboarding-task-heading">
                <p class="onboarding-eyebrow">01 / Terminal pairing</p>
                <h2>Pair this browser.</h2>
              </header>
              <p>
                Enter the one-time pairing code shown in the terminal that started MONOLITH. This prevents another browser from claiming your installation.
              </p>
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <div class="owner-field">
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
                  aria-describedby={
                    if @error, do: "setup-error setup-pairing-hint", else: "setup-pairing-hint"
                  }
                />
              </div>
              <p id="setup-pairing-hint" class="owner-supporting">
                Codes expire after 15 minutes and can be used once. Restart the server for a new code; your setup files are preserved.
              </p>
              <button type="submit" class="workspace-action workspace-action-primary">Pair this browser</button>
            </form>
            <form
              :if={@paired?}
              id="setup-password-form"
              action="/setup/password"
              method="post"
              class="owner-unlock-form"
            >
              <header class="onboarding-task-heading">
                <p class="onboarding-eyebrow">02 / Local owner</p>
                <h2>
                  {if @interrupted?, do: "Resume encrypted setup.", else: "Create the local owner."}
                </h2>
              </header>
              <p>
                Your password unlocks a dedicated macOS keychain and encrypted local database. Google accounts are connected separately.
              </p>
              <p id="setup-recovery-warning" class="onboarding-note">
                <strong>There is no password reset or recovery.</strong>
                If you forget this password, you permanently lose access to your encrypted data. Save it in your password manager.
              </p>
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <div class="owner-field">
                <label for="setup-password">{if @interrupted?,
                  do: "Original password",
                  else: "New password"}</label>
                <input
                  id="setup-password"
                  name="password"
                  type="password"
                  autocomplete={if @interrupted?, do: "current-password", else: "new-password"}
                  required
                  minlength="12"
                  maxlength="1024"
                  aria-describedby={
                    if @error,
                      do: "setup-error setup-password-hint setup-recovery-warning",
                      else: "setup-password-hint setup-recovery-warning"
                  }
                  class="owner-password"
                />
                <p id="setup-password-hint" class="owner-supporting">
                  At least 12 characters; at most 1024 UTF-8 bytes.
                </p>
              </div>
              <div class="owner-field">
                <label for="setup-password-confirmation">Confirm password</label>
                <input
                  id="setup-password-confirmation"
                  name="password_confirmation"
                  type="password"
                  autocomplete={if @interrupted?, do: "current-password", else: "new-password"}
                  required
                  minlength="12"
                  maxlength="1024"
                  aria-describedby={
                    if @error,
                      do: "setup-error setup-recovery-warning",
                      else: "setup-recovery-warning"
                  }
                  class="owner-password"
                />
              </div>
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
              <p class="owner-supporting">
                Creating the vault may take up to two minutes. If macOS requests authorization for the dedicated MONOLITH keychain, use this same password. Keep this page open until setup finishes.
              </p>
              <button type="submit" class="workspace-action workspace-action-primary">{if @interrupted?,
                do: "Resume encrypted setup",
                else: "Create encrypted workspace"}</button>
            </form>
          </div>
        </section>
      </main>
      <Layouts.brand id="first-run-brand" static />
    </Layouts.stage>
    """
  end
end
