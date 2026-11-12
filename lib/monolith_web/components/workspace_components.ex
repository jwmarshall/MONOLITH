defmodule MonolithWeb.WorkspaceComponents do
  @moduledoc "Workspace entry surfaces, with management kept outside the opening control."
  use MonolithWeb, :html

  attr :id, :string, required: true
  attr :workspace, :map, required: true
  attr :health, :map, default: nil

  def card(assigns) do
    ~H"""
    <article id={@id} class="workspace-card">
      <.link
        id={"open-#{@workspace.id}"}
        patch={MonolithWeb.HomeNavigation.workspace_path(@workspace.id)}
        class="workspace-card-open"
        aria-label={"Open #{@workspace.name}"}
        aria-describedby={"workspace-health-#{@workspace.id}"}
      >
        <span class="workspace-card-name">{@workspace.name}</span>
        <span id={"workspace-health-#{@workspace.id}"} class="workspace-card-health">
          <%= cond do %>
            <% is_nil(@health) -> %>
              <.status_signal
                id={"workspace-signal-#{@workspace.id}"}
                state={:unknown}
                label="Connection status unavailable"
                embedded
              />
            <% @health.total == 0 -> %>
              <span>No integrations yet</span>
            <% @health.problems == [] -> %>
              <.status_signal
                id={"workspace-signal-#{@workspace.id}"}
                state={:ready}
                label="No reported problems · last-known connection metadata, not a live check"
                embedded
              />
            <% true -> %>
              <span class="connection-warning">Connection needs attention</span>
              <span :for={account <- @health.problems} class="workspace-card-problem">
                {account.email} · {problem_label(account)}
              </span>
          <% end %>
        </span>
        <.icon name="hero-arrow-up-right" class="workspace-card-arrow size-5" />
      </.link>
      <.workspace_menu workspace={@workspace} />
    </article>
    """
  end

  attr :workspace, :map, required: true
  attr :current, :boolean, default: false

  def workspace_menu(assigns) do
    ~H"""
    <details id={"workspace-menu-#{@workspace.id}"} class="workspace-menu">
      <summary aria-label={"Manage #{@workspace.name}"} title={"Manage #{@workspace.name}"}>
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
      </summary>
      <div class="workspace-menu-actions">
        <button
          id={if @current, do: "rename-current-workspace", else: "rename-#{@workspace.id}"}
          type="button"
          class="workspace-action workspace-action-quiet"
          phx-click={
            JS.remove_attribute("open", to: "#workspace-menu-#{@workspace.id}")
            |> JS.push("rename_workspace")
          }
          phx-value-id={@workspace.id}
          aria-label={"Rename #{@workspace.name}"}
        >
          <.icon name="hero-pencil-square" class="size-4" /> Rename
        </button>
      </div>
    </details>
    """
  end

  defp problem_label(%{status: :reconnect}), do: "Reconnect required"
  defp problem_label(%{last_error: :rate_limited}), do: "Rate limited"
  defp problem_label(%{last_error: :keychain}), do: "Check credentials"
  defp problem_label(_), do: "Last check failed"
end
