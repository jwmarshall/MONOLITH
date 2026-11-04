defmodule LovelaceWeb.HomeGitHub do
  @moduledoc "Installation-owner readouts; authorization and provider work belong to the GitHub domain."
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]
  alias Lovelace.GitHub.Auth
  alias Lovelace.Owner.Actions

  @owner %{role: :local_owner}

  def init(socket, session) do
    if connected?(socket) do
      Process.send_after(self(), :github_tick, 60_000)
      Process.send_after(self(), :github_auth_tick, 1_000)
      Phoenix.PubSub.subscribe(Lovelace.PubSub, "github:directory")
    end

    assign(socket,
      github_organizations: [],
      github_connections: [],
      github_auth: %{status: :idle},
      github_auth_key: Actions.digest(session["owner_session_token"]),
      github_configured: Auth.configured?(),
      github_installation_url: Auth.installation_url(),
      github_memberships: [],
      github_subscriptions: [],
      github_error: false,
      github_now: DateTime.utc_now()
    )
  end

  def reload(socket) do
    case Lovelace.GitHub.directory(actor: @owner) do
      {:ok, %{organizations: organizations, memberships: memberships, connections: connections}} ->
        organizations =
          Enum.reject(
            organizations,
            &(&1.status == :disconnected && &1.last_error != :keychain && !&1.legacy_credential)
          )

        ids = Enum.map(organizations, & &1.id)
        old = socket.assigns.github_subscriptions

        if connected?(socket) do
          Enum.each(old -- ids, &Phoenix.PubSub.unsubscribe(Lovelace.PubSub, "github:#{&1}"))
          Enum.each(ids -- old, &Phoenix.PubSub.subscribe(Lovelace.PubSub, "github:#{&1}"))
        end

        assign(socket,
          github_organizations: organizations,
          github_memberships: memberships,
          github_connections: connections,
          github_subscriptions: ids,
          github_error: false,
          github_now: DateTime.utc_now()
        )

      _ ->
        assign(socket,
          github_organizations: [],
          github_memberships: [],
          github_connections: [],
          github_error: true,
          github_now: DateTime.utc_now()
        )
    end
  end

  def handle_info(:github_tick, socket) do
    Process.send_after(self(), :github_tick, 60_000)
    {:noreply, reload(socket)}
  end

  def handle_info(:github_auth_tick, socket) do
    active = socket.assigns.connections && socket.assigns.connection_view == :github

    auth =
      if active,
        do: Auth.status(socket.assigns.github_auth_key),
        else: socket.assigns.github_auth

    delay = if active && auth.status in [:starting, :pending], do: 1_000, else: 5_000
    Process.send_after(self(), :github_auth_tick, delay)
    changed = socket.assigns.github_auth != auth
    socket = assign(socket, github_auth: auth)
    {:noreply, if(changed && auth.status == :connected, do: reload(socket), else: socket)}
  end

  def handle_info(:github_directory_changed, socket), do: {:noreply, reload(socket)}

  def handle_info({:github_changed, id}, socket) do
    {:noreply, if(id in socket.assigns.github_subscriptions, do: reload(socket), else: socket)}
  end

  def handle_event("github:refresh", %{"id" => id}, socket) do
    if id in socket.assigns.github_subscriptions do
      case Lovelace.GitHub.refresh(id, actor: @owner) do
        {:ok, _} ->
          {:noreply,
           put_flash(socket, :info, "GitHub refresh requested. Rate limits may delay it.")}

        _ ->
          {:noreply,
           put_flash(socket, :error, "GitHub could not refresh. Check Connections and try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  def workspace_connections(socket) do
    by_id =
      Map.new(socket.assigns.github_organizations, fn org ->
        {org.id,
         %{
           id: org.id,
           email: "GitHub · " <> org.login,
           status: org.status,
           last_error: org.last_error
         }}
      end)

    Enum.reduce(socket.assigns.github_memberships, %{}, fn member, grouped ->
      case Map.get(by_id, member.organization_id) do
        nil -> grouped
        connection -> Map.update(grouped, member.workspace_id, [connection], &[connection | &1])
      end
    end)
  end

  @result_messages %{
    "pending" => {:info, "Enter the displayed code on GitHub to authorize LOVELACE."},
    "authorized" =>
      {:info,
       "GitHub sign-in completed before cancellation. Use Disconnect account if you want to remove it."},
    "cancelled" => {:info, "GitHub sign-in cancelled locally."},
    "discovered" =>
      {:info, "GitHub installations refreshed. Choose an owner to add to a workspace."},
    "attached" => {:info, "GitHub owner added to workspace."},
    "detached" =>
      {:info, "GitHub owner removed from this workspace. Its connection is unchanged."},
    "disconnected" => {:info, "GitHub owner removed from every workspace and its cache cleared."},
    "signed_out" =>
      {:info,
       "GitHub account disconnected locally. Revoke app authorization separately in GitHub if no longer needed."},
    "configuration" =>
      {:error,
       "Configure the public GitHub App client ID and app slug, and enable device flow. See docs/DEVELOPMENT.md."},
    "keychain_failed" =>
      {:error,
       "GitHub credential storage failed. The token could not be read, saved or removed in the dedicated LOVELACE keychain. Check native helper access; do not reset the vault."},
    "access_failed" =>
      {:error,
       "GitHub access expired or was denied. Sign in again and check the app's installation, selected repositories and organization approval."},
    "rate_limited" =>
      {:error, "GitHub rate-limited the connection attempt. Wait before trying again."},
    "provider_failed" =>
      {:error,
       "GitHub could not load the requested information. Check connectivity and GitHub App installation access, then try again."},
    "invalid_input" =>
      {:error,
       "GitHub connection details are invalid. Reload Connections and choose an available workspace or owner."},
    "unavailable" =>
      {:error,
       "GitHub could not save the local connection. Reload Connections and try again with LOVELACE unlocked; the connection or local storage may have changed."},
    "failed" =>
      {:error,
       "GitHub could not be updated. Check app installation access and dedicated keychain access."}
  }

  def resume(socket, params) do
    case @result_messages[params["github"]] do
      {level, message} -> put_flash(socket, level, message)
      nil -> socket
    end
  end
end
