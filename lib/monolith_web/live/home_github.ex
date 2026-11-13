defmodule MonolithWeb.HomeGitHub do
  @moduledoc "Installation-owner readouts; authorization and provider work belong to the GitHub domain."
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]
  alias Monolith.GitHub.Auth
  alias Monolith.Owner.Actions
  alias MonolithWeb.HomeConnectionDiagnostic

  @owner %{role: :local_owner}
  @authorization_errors ~w(authorization_unlinked authorization_unmatched authorization_denied callback_invalid authorization_failed keychain_failed locked)

  def init(socket, session) do
    if connected?(socket) do
      Process.send_after(self(), :github_tick, 60_000)
      Process.send_after(self(), :github_auth_tick, 1_000)
      Phoenix.PubSub.subscribe(Monolith.PubSub, "github:directory")
    end

    assign(socket,
      github_organizations: [],
      github_connections: [],
      github_auth: %{status: :idle},
      github_authorization_error: authorization_error(session["github_authorization_result"]),
      github_auth_key: Actions.digest(session["owner_session_token"]),
      github_configured: false,
      github_configuration_status: :unknown,
      github_installation_url: nil,
      github_callback_url: Auth.callback_url(),
      github_memberships: [],
      github_subscriptions: [],
      github_error: false,
      github_now: DateTime.utc_now()
    )
    |> HomeConnectionDiagnostic.init(:github)
  end

  def open(socket), do: HomeConnectionDiagnostic.open(socket, :github)

  @doc "Selects an existing workspace owner's read model without requesting provider work."
  def select_activity(socket, destination) do
    workspace = socket.assigns.selected

    member? =
      Enum.any?(socket.assigns.github_memberships, fn member ->
        member.workspace_id == destination.workspace_id &&
          member.organization_id == destination.organization_id
      end)

    owner =
      Enum.find(socket.assigns.github_organizations, fn organization ->
        organization.id == destination.organization_id && organization.status == :ready
      end)

    if workspace && workspace.id == destination.workspace_id && member? && owner do
      {:ok, assign(socket, page_title: "#{owner.login} · GitHub")}
    else
      :error
    end
  end

  def reload(socket) do
    case Monolith.GitHub.directory(actor: @owner) do
      {:ok, %{organizations: organizations, memberships: memberships, connections: connections}} ->
        organizations =
          Enum.reject(
            organizations,
            &(&1.status == :disconnected && &1.last_error != :keychain && !&1.legacy_credential)
          )

        ids = Enum.map(organizations, & &1.id)
        old = socket.assigns.github_subscriptions

        if connected?(socket) do
          Enum.each(old -- ids, &Phoenix.PubSub.unsubscribe(Monolith.PubSub, "github:#{&1}"))
          Enum.each(ids -- old, &Phoenix.PubSub.subscribe(Monolith.PubSub, "github:#{&1}"))
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

  def handle_info({:connection_diagnostic, :github, _} = message, socket),
    do: HomeConnectionDiagnostic.handle_info(message, socket)

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

    delay = if active && auth.status in [:pending, :exchanging], do: 1_000, else: 5_000
    Process.send_after(self(), :github_auth_tick, delay)
    changed = socket.assigns.github_auth != auth

    socket =
      assign(socket,
        github_auth: auth,
        github_authorization_error:
          if(auth.status == :connected, do: nil, else: socket.assigns.github_authorization_error)
      )

    {:noreply, refresh_observation(socket, active, auth, changed)}
  end

  def handle_info(:github_directory_changed, socket), do: {:noreply, reload(socket)}

  def handle_info({:github_changed, id}, socket) do
    {:noreply, if(id in socket.assigns.github_subscriptions, do: reload(socket), else: socket)}
  end

  defp refresh_observation(socket, active, auth, changed) do
    observing_discovery =
      active and
        Enum.any?(
          socket.assigns.github_connections,
          &(&1.discovery_status in [:pending, :running])
        )

    reload? = observing_discovery or (changed and auth.status == :connected)
    if reload?, do: reload(socket), else: socket
  end

  def handle_event("github:refresh", %{"id" => id}, socket) do
    if id in socket.assigns.github_subscriptions do
      case Monolith.GitHub.refresh(id, actor: @owner) do
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

  @result_messages %{
    "pending" => {:info, "Complete GitHub authorization in the browser to connect your account."},
    "authorized" =>
      {:info,
       "GitHub account connected. Add an account, organization or selected repositories to a workspace."},
    "settings_saved" =>
      {:info,
       "GitHub app settings saved in the dedicated keychain. No provider access was requested."},
    "invalid_client_id" =>
      {:error,
       "Client ID is invalid. Copy the GitHub App's Client ID, not its App ID, without spaces or line breaks. Nothing was saved or sent to GitHub."},
    "invalid_client_secret" =>
      {:error,
       "Client secret is invalid. Copy the generated client secret, not a private key, without spaces or line breaks. Nothing was saved or sent to GitHub."},
    "invalid_app_slug" =>
      {:error,
       "App URL or slug is invalid. Enter https://github.com/apps/ followed by the lowercase app slug, or just the slug. Nothing was saved or sent to GitHub."},
    "invalid_settings" =>
      {:error,
       "Client ID, client secret and app URL or slug are all required. Reload Connections and enter all three fields."},
    "locked" =>
      {:error,
       "MONOLITH locked before the GitHub operation could finish. Unlock it and try again."},
    "cancelled" => {:info, "GitHub connection attempt cancelled locally."},
    "discovery_queued" =>
      {:info,
       "GitHub account access refresh requested. Its status remains available here after reload."},
    "attached" => {:info, "GitHub owner added to workspace."},
    "detached" =>
      {:info, "GitHub owner removed from this workspace. Its connection is unchanged."},
    "disconnected" => {:info, "GitHub owner removed from every workspace and its cache cleared."},
    "signed_out" =>
      {:info,
       "GitHub account disconnected locally. Revoke app authorization separately in GitHub if no longer needed."},
    "configuration" =>
      {:error,
       "Save the GitHub App Client ID, client secret and app slug here, and check its exact callback URL."},
    "keychain_failed" =>
      {:error,
       "GitHub credential storage failed. The credentials could not be read, saved or removed in the dedicated MONOLITH keychain. Check native helper access; do not reset the vault."},
    "access_failed" =>
      {:error,
       "This GitHub account needs to be connected again. Check the app's repository access and organization approval, then connect the account again below."},
    "authorization_unlinked" =>
      {:error,
       "GitHub returned without a MONOLITH connection request. Installing the app or signing in to GitHub does not connect an account here. Start the connection again below to authorize MONOLITH."},
    "authorization_unmatched" =>
      {:error,
       "This GitHub return does not match an active connection request. It may be an older attempt or a different browser session. No new account was connected. Start the connection again from this localhost browser."},
    "authorization_denied" =>
      {:error,
       "GitHub authorization was cancelled or denied. No new account was connected. You can start the connection again below."},
    "callback_invalid" =>
      {:error,
       "GitHub returned an unexpected authorization response. No new account was connected. Start the connection again from MONOLITH; do not reuse an old GitHub return URL."},
    "authorization_failed" =>
      {:error,
       "GitHub authorization could not finish. No new account was connected. Check the saved app credentials, callback URL and GitHub connectivity, then try again."},
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
       "GitHub could not save the local connection. Reload Connections and try again with MONOLITH unlocked; the connection or local storage may have changed."},
    "failed" =>
      {:error,
       "GitHub could not be updated. Check app installation access and dedicated keychain access."}
  }

  def resume(socket, params) do
    result = params["github"]

    case @result_messages[result] do
      {:error, message} when result in @authorization_errors ->
        assign(socket, github_authorization_error: message)

      {level, message} ->
        put_flash(socket, level, message)

      nil ->
        socket
    end
  end

  defp authorization_error(result) when result in @authorization_errors do
    {:error, message} = Map.fetch!(@result_messages, result)
    message
  end

  defp authorization_error(_), do: nil
end
