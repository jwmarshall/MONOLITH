defmodule MonolithWeb.OwnerHTML do
  use MonolithWeb, :html

  def unlock(assigns) do
    ~H"""
    <Layouts.stage id="owner-stage" class="stage-static" background={@background} static>
      <main
        id="main-content"
        class="workspace-glass owner-glass owner-threshold"
        aria-labelledby="owner-unlock-heading"
        tabindex="-1"
      >
        <section class="owner-content">
          <h1 id="owner-unlock-heading" class="sr-only">Unlock MONOLITH.</h1>
          <div class="brand-lockup" aria-hidden="true">
            <Layouts.monogram id="owner-monolith-mark" />
            <span class="brand-wordmark">MONOLITH</span>
          </div>
          <div :if={@error?} id="owner-unlock-error" class="owner-notice" role="alert">
            <strong>Couldn’t unlock MONOLITH.</strong>
            <p>Check your owner password and try again. Protected content is still locked.</p>
            <a :if={@configured?} href="#owner-password">Return to owner password</a>
          </div>
          <form
            :if={@configured?}
            id="owner-unlock-form"
            action="/unlock"
            method="post"
            class="owner-unlock-form"
          >
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <div class="owner-field">
              <label for="owner-password">Owner password</label>
              <input
                id="owner-password"
                name="password"
                type="password"
                autocomplete="current-password"
                required
                maxlength="1024"
                aria-invalid={@error? && "true"}
                aria-describedby={
                  if @error?,
                    do: "owner-unlock-error owner-recovery-note",
                    else: "owner-recovery-note"
                }
                class="owner-password"
              />
            </div>
            <button type="submit" class="workspace-action workspace-action-primary">Unlock</button>
            <p id="owner-recovery-note" class="owner-supporting">
              There’s no password reset or recovery. Your password unlocks the encrypted workspace and its dedicated keychain.
            </p>
          </form>
          <div
            :if={@setup_state in [:new, :setup_incomplete]}
            id="owner-setup-instructions"
            class="owner-notice"
          >
            <p>
              Pair with the terminal that started MONOLITH. Interrupted setup requires the original password.
            </p>
            <a href="/setup" class="workspace-action workspace-action-primary">Continue secure setup</a>
          </div>
          <div
            :if={@setup_state == :migration_required}
            id="owner-migration-instructions"
            class="owner-notice"
            role="status"
          >
            <strong>Encrypted-vault migration required.</strong>
            <p>
              Stop the server and run <code>bin/monolith mix monolith.vault.migrate</code>
              in your local MONOLITH terminal.
            </p>
            <p>Existing data and credentials will not be changed by this screen.</p>
          </div>
          <div
            :if={@setup_state == :unavailable}
            id="owner-storage-unavailable"
            class="owner-notice"
            role="alert"
          >
            <strong>Protected local storage is unavailable.</strong>
            <p>Preserve the vault and database; do not reset or repeat initial setup.</p>
          </div>
        </section>
      </main>
    </Layouts.stage>
    """
  end
end
