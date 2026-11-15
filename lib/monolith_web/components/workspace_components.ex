defmodule MonolithWeb.WorkspaceComponents do
  @moduledoc "Full-area workspace destinations and a detail-page Rename control."
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
        <p class="section-register">Workspace</p>
        <h2 class="workspace-card-name">{@workspace.name}</h2>
        <span id={"workspace-health-#{@workspace.id}"} class="workspace-card-health">
          <span class="workspace-card-memberships">{membership_summary(@health)}</span>
          <.status_signal
            :if={is_nil(@health)}
            id={"workspace-signal-#{@workspace.id}"}
            state={:unknown}
            label="Connection status unavailable"
            embedded
          />
          <span :if={@health && @health.problems != []} class="connection-warning">
            Connection needs attention
          </span>
          <span
            :for={account <- if(@health, do: @health.problems, else: [])}
            class="workspace-card-problem"
          >{account.email} · {problem_label(account)}</span>
        </span>
      </.link>
    </article>
    """
  end

  attr :workspace, :map, required: true

  def rename_button(assigns) do
    ~H"""
    <button
      id="rename-current-workspace"
      type="button"
      class="workspace-action workspace-rename"
      phx-click="rename_workspace"
      phx-value-id={@workspace.id}
      aria-label={"Rename #{@workspace.name}"}
    >Rename</button>
    """
  end

  defp membership_summary(%{google_accounts: google, github_installations: github})
       when is_integer(google) and is_integer(github) do
    "#{google} Google #{if google == 1, do: "account", else: "accounts"} · " <>
      "#{github} GitHub #{if github == 1, do: "installation", else: "installations"}"
  end

  defp membership_summary(_), do: "Integration membership unavailable"

  defp problem_label(%{status: :reconnect}), do: "Reconnect required"
  defp problem_label(%{last_error: :rate_limited}), do: "Rate limited"
  defp problem_label(%{last_error: :keychain}), do: "Check credentials"
  defp problem_label(_), do: "Last check failed"
end
