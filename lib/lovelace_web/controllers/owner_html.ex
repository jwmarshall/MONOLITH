defmodule LovelaceWeb.OwnerHTML do
  use LovelaceWeb, :html

  def unlock(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-100 text-base-content flex items-center justify-center px-6">
      <section class="w-full max-w-sm space-y-6" aria-labelledby="owner-unlock-heading">
        <p class="text-sm tracking-[0.3em] text-primary">LOVELACE</p>
        <h1 id="owner-unlock-heading" class="text-2xl">Unlock your workspace</h1>
        <p :if={@error?} id="owner-unlock-error" role="alert">
          Unable to unlock. Please try again later.
        </p>
        <form
          :if={@configured?}
          id="owner-unlock-form"
          action="/unlock"
          method="post"
          class="space-y-4"
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
            class="w-full rounded border border-primary/40 bg-base-200 p-3"
          />
          <button type="submit" class="rounded bg-primary px-5 py-3 text-primary-content">Unlock</button>
        </form>
        <p :if={!@configured?} id="owner-setup-instructions">
          Local unlock is not configured. In the local LOVELACE terminal, run <code>mix lovelace.owner.setup</code>. There is no web signup or password setup.
        </p>
      </section>
    </main>
    """
  end
end
