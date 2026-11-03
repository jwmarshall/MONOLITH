defmodule LovelaceWeb.OwnerHTML do
  use LovelaceWeb, :html

  def unlock(assigns) do
    ~H"""
    <Layouts.stage id="owner-stage" class="stage-static" background={@background} static>
      <main
        id="main-content"
        class="workspace-glass owner-glass"
        aria-labelledby="owner-unlock-heading"
      >
        <section class="owner-content space-y-6">
          <h1 id="owner-unlock-heading" class="sr-only">Unlock LOVELACE</h1>
          <p :if={@error?} id="owner-unlock-error" role="alert">
            Unable to unlock. Please try again later.
          </p>
          <form
            :if={@configured?}
            id="owner-unlock-form"
            action="/unlock"
            method="post"
            class="owner-unlock-form"
          >
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <label for="owner-password" class="block">Password</label>
            <input
              id="owner-password"
              name="password"
              type="password"
              autocomplete="current-password"
              required
              maxlength="1024"
              aria-describedby={@error? && "owner-unlock-error"}
              class="owner-password"
            />
            <button type="submit" class="owner-submit">Unlock</button>
          </form>
          <p :if={!@configured?} id="owner-setup-instructions">
            Local unlock is not configured. In the local LOVELACE terminal, run <code>mix lovelace.owner.setup</code>. There is no web signup or password setup.
          </p>
        </section>
      </main>
    </Layouts.stage>
    """
  end
end
