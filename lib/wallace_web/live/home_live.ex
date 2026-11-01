defmodule WallaceWeb.HomeLive do
  @moduledoc """
  The initial workspace shell. Integration and project features are not connected yet.
  """
  use WallaceWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Workspace")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="workspace" aria-labelledby="workspace-title">
        <p class="text-xs uppercase tracking-[0.25em] text-primary">Personal workspace</p>
        <h1 id="workspace-title" class="mt-5 text-5xl font-light tracking-tight sm:text-6xl">
          Space for deliberate work.
        </h1>
        <p class="mt-6 max-w-xl text-base leading-7 text-stone-400">
          A private workbench for your projects and conversations.
          Each account stays separate. Each project has its place.
        </p>

        <div class="mt-16 grid gap-px border border-base-300 bg-base-300 lg:grid-cols-3">
          <section id="accounts-empty" class="bg-base-100 p-8" aria-labelledby="accounts-title">
            <h2 id="accounts-title" class="text-sm font-medium">Gmail accounts</h2>
            <p class="mt-6 text-stone-300">No accounts connected.</p>
            <p class="mt-3 text-sm leading-6 text-stone-400">
              Account connection is not implemented yet. Inboxes will never be combined.
            </p>
          </section>

          <section id="projects-empty" class="bg-base-100 p-8" aria-labelledby="projects-title">
            <h2 id="projects-title" class="text-sm font-medium">Projects</h2>
            <p class="mt-6 text-stone-300">A place for context.</p>
            <p class="mt-3 text-sm leading-6 text-stone-400">
              Projects will belong to one account, with conversations linked explicitly.
            </p>
          </section>

          <section id="sync-status" class="bg-base-100 p-8" aria-labelledby="sync-title">
            <h2 id="sync-title" class="text-sm font-medium">Synchronization</h2>
            <p class="mt-6 text-stone-300">Not configured.</p>
            <p class="mt-3 text-sm leading-6 text-stone-400">
              Background sync and job reporting will appear here once Gmail is connected.
            </p>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
