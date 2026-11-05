defmodule LovelaceWeb.GitHubComponents do
  @moduledoc "Read-only GitHub App installations and bounded pull request orientation."
  use LovelaceWeb, :html

  attr :organizations, :list, required: true
  attr :memberships, :list, required: true
  attr :workspace_options, :list, required: true
  attr :error, :boolean, required: true
  attr :now, :any, required: true

  def dashboard(assigns) do
    assigns =
      assign(assigns, :organizations, Enum.filter(assigns.organizations, &(&1.status == :ready)))

    ~H"""
    <section id="github-readouts" class="github-readouts" aria-labelledby="github-home-heading">
      <div class="home-section-heading">
        <h3 id="github-home-heading" class="home-eyebrow">Pull requests</h3>
        <.link
          :if={@organizations != []}
          patch="/connections/github"
          class="workspace-action workspace-action-link home-section-meta"
        >
          GitHub connections
        </.link>
      </div>
      <p :if={@error} class="connection-warning" role="alert">
        GitHub information is unavailable. Your connections have not been changed.
      </p>
      <div :if={!@error && @organizations == []} class="empty-state">
        <.icon name="hero-code-bracket" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h4 class="empty-state-title">No GitHub readouts yet</h4>
          <p class="empty-state-copy">
            Connect a GitHub account or organization to see read-only pull requests. Review existing access in Connections.
          </p>
          <div class="empty-state-actions">
            <.link patch="/connections/github" class="workspace-action workspace-action-link">
              Connect GitHub
            </.link>
          </div>
        </div>
      </div>
      <article :for={org <- @organizations} id={"github-org-#{org.id}"} class="github-organization">
        <div class="github-org-heading">
          <div>
            <h4>{org.login}</h4>
            <p class="mail-muted">{workspace_names(org.id, @memberships, @workspace_options)}</p>
          </div>
          <button
            type="button"
            class="workspace-action"
            phx-click="github:refresh"
            phx-value-id={org.id}
          >
            Refresh<span class="sr-only">{org.login} pull requests</span>
          </button>
        </div>
        <.health organization={org} now={@now} />
        <p :if={observed?(org, @now)} class="github-summary">
          {length(org.pull_requests)} shown<span :if={org.total_count != nil}> · {org.total_count} open in accessible repositories</span>
          <span :if={count(org.pull_requests, :review) > 0}> · {count(org.pull_requests, :review)} awaiting review</span>
          <span :if={count(org.pull_requests, :failed) > 0}> · {count(org.pull_requests, :failed)} with failing checks</span>
          <span :if={count(org.pull_requests, :draft) > 0}> · {count(org.pull_requests, :draft)} draft</span>
        </p>
        <p :if={org.truncated && observed?(org, @now)} class="connection-warning">
          Partial results · some pull requests or status fields may be unavailable. Most recently updated first.
        </p>
        <p
          :if={
            observed?(org, @now) && org.pull_requests == [] && org.total_count == 0 && !org.truncated
          }
          class="mail-muted"
        >
          No open pull requests found in repositories accessible to this app installation.
        </p>
        <p
          :if={
            observed?(org, @now) && org.pull_requests == [] && (org.total_count != 0 || org.truncated)
          }
          class="mail-muted"
        >
          Pull request details are unavailable in these partial results.
        </p>
        <ul :if={observed?(org, @now) && org.pull_requests != []} class="github-pr-list">
          <li :for={pr <- org.pull_requests} class="github-pr">
            <div class="github-pr-main">
              <a
                href={pr["url"]}
                target="_blank"
                rel="noopener noreferrer"
                class="github-pr-title workspace-action-link"
              >
                {pr["title"]}<span class="sr-only"> (opens GitHub in a new tab)</span>
              </a>
              <p class="github-pr-meta">
                {pr["repository"]} #{pr["number"]} · {pr["author"] || "Deleted user"}
              </p>
            </div>
            <div class="github-pr-state">
              <span>{review_label(pr)}</span>
              <span class={if pr["checks"] in ["FAILURE", "ERROR"], do: "github-check-failed"}>
                {checks_label(pr["checks"])}
              </span>
              <time datetime={pr["updated_at"]}>Updated {date_label(pr["updated_at"])}</time>
            </div>
          </li>
        </ul>
      </article>
    </section>
    """
  end

  attr :organizations, :list, required: true
  attr :connections, :list, required: true
  attr :auth, :map, required: true
  attr :configured, :boolean, required: true
  attr :installation_url, :string, default: nil
  attr :memberships, :list, required: true
  attr :workspace_options, :list, required: true
  attr :error, :boolean, required: true
  attr :now, :any, required: true

  def connections(assigns) do
    ~H"""
    <section
      id="github-connections"
      class="github-connections"
      aria-labelledby="github-connections-heading"
    >
      <div class="github-section-heading">
        <h3 id="github-connections-heading">GitHub</h3>
        <span class="mail-muted">Read-only pull requests</span>
      </div>
      <p :if={@error} class="connection-warning" role="alert">
        GitHub connections could not be loaded. Try reloading.
      </p>
      <div id="github-authorization" class="connection-card empty-state empty-state-card">
        <.icon name="hero-code-bracket" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h4 class="empty-state-title">
            {if @configured, do: "Connect with GitHub", else: "Set up GitHub"}
          </h4>
          <p class="empty-state-copy">
            {if @configured,
              do:
                "Install the read-only app on your personal account or approved organizations, then sign in. Organization membership alone does not grant app access.",
              else:
                "Connect a read-only GitHub App to see pull requests on Home, grouped by account or organization."}
          </p>
          <p :if={!@configured} class="empty-state-copy" role="status">
            GitHub App setup is required before you can sign in.
          </p>
          <details
            :if={!@configured}
            id="github-app-setup"
            class="connection-help"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary class="workspace-action workspace-action-primary">
              View setup instructions
            </summary>
            <p class="empty-state-copy">
              Follow <code>docs/DEVELOPMENT.md</code>
              to register a read-only GitHub App with device flow enabled.
              Set <code>LOVELACE_GITHUB_CLIENT_ID</code>
              and <code>LOVELACE_GITHUB_APP_SLUG</code>
              in <code>.env</code>, then restart LOVELACE.
              No personal access token or client secret is needed.
            </p>
          </details>
          <a
            :if={@configured && @installation_url}
            id="github-install-app"
            href={@installation_url}
            target="_blank"
            rel="noopener noreferrer"
            class="workspace-action workspace-action-link"
          >
            Install / manage app access<span class="sr-only"> (opens GitHub in a new tab)</span>
          </a>
          <.form
            :if={@configured && @auth.status not in [:starting, :pending]}
            for={%{}}
            id="github-sign-in-form"
            action="/connections/github"
            method="post"
          >
            <input type="hidden" name="operation" value="sign_in" />
            <button type="submit" class="workspace-action workspace-action-primary">Sign in with GitHub</button>
          </.form>
          <div
            :if={@auth.status in [:starting, :pending]}
            id="github-device-authorization"
            role="status"
          >
            <p :if={@auth.status == :starting} class="mail-muted">
              Requesting a GitHub authorization code…
            </p>
            <p :if={@auth.status == :pending} class="mail-muted">
              Enter <strong id="github-user-code">{@auth.user_code}</strong>
              at <a
                href="https://github.com/login/device"
                target="_blank"
                rel="noopener noreferrer"
                class="workspace-action-link"
              >github.com/login/device<span class="sr-only"> (opens in a new tab)</span></a>.
              Use only this code, requested here. Waiting for GitHub approval; expires within 15 minutes.
            </p>
            <.form for={%{}} id="github-cancel-sign-in" action="/connections/github" method="post">
              <input type="hidden" name="operation" value="cancel_sign_in" />
              <button type="submit" class="workspace-action">Cancel sign-in</button>
            </.form>
          </div>
          <p :if={@auth.status == :connected} id="github-authorized" class="mail-muted" role="status">
            GitHub sign-in complete. Add an accessible owner to a workspace below.
          </p>
          <p
            :if={@auth.status == :failed}
            id="github-authorization-error"
            class="connection-warning"
            role="alert"
          >
            {auth_error(@auth.error)}
          </p>
        </div>
      </div>
      <article
        :for={connection <- @connections}
        :if={connection.status != :disconnected || connection.last_error == :keychain}
        id={"github-account-#{connection.id}"}
        class="connection-card"
      >
        <div class="github-org-heading">
          <div>
            <h4>Signed in as {connection.login}</h4>
            <p :if={connection.status in [:reauthorization, :refreshing]} class="connection-warning">
              Sign in again to restore this account's access.
            </p>
            <p :if={connection.status == :disconnected} class="connection-warning" role="alert">
              Disconnected locally. Credential removal failed; retry to remove it from the dedicated keychain.
            </p>
          </div>
          <div class="mail-actions">
            <.form
              :if={connection.status == :ready}
              for={%{}}
              id={"github-discover-#{connection.id}"}
              action="/connections/github"
              method="post"
            >
              <input type="hidden" name="operation" value="discover" />
              <input type="hidden" name="connection_id" value={connection.id} />
              <button type="submit" class="workspace-action">Refresh app installations</button>
            </.form>
            <.form
              for={%{}}
              id={"github-sign-out-#{connection.id}"}
              action="/connections/github"
              method="post"
            >
              <input type="hidden" name="operation" value="disconnect_account" />
              <input type="hidden" name="connection_id" value={connection.id} />
              <button
                type="submit"
                class="workspace-action workspace-action-danger"
                data-confirm={"Disconnect #{connection.login}, remove all its workspace memberships and clear its local PR caches? App authorization is not revoked in GitHub."}
              >
                {if connection.status == :disconnected,
                  do: "Retry credential removal",
                  else: "Disconnect account"}
              </button>
            </.form>
          </div>
        </div>
        <p :if={connection.last_error && connection.status == :ready} class="connection-warning">
          {error_label(connection.last_error)}
        </p>
      </article>
      <h4 :if={@organizations != []}>Repository owners</h4>
      <article :for={org <- @organizations} id={"github-connection-#{org.id}"} class="connection-card">
        <div class="github-org-heading">
          <div>
            <h4>{org.login} <span class="mail-muted">· {owner_label(org)}</span></h4>
            <p class="mail-muted">{workspace_names(org.id, @memberships, @workspace_options)}</p>
          </div>
          <div class="mail-actions">
            <button
              :if={org.status == :ready}
              type="button"
              class="workspace-action"
              phx-click="github:refresh"
              phx-value-id={org.id}
            >Refresh</button>
            <.form
              for={%{}}
              action="/connections/github"
              method="post"
              id={"github-disconnect-#{org.id}"}
            >
              <input type="hidden" name="operation" value="disconnect" />
              <input type="hidden" name="organization_id" value={org.id} />
              <button
                type="submit"
                class="workspace-action workspace-action-danger"
                data-confirm={"Remove #{org.login} from every workspace and clear its local PR cache? Your GitHub account sign-in remains connected."}
              >
                {if org.status == :disconnected,
                  do: "Remove retained credential",
                  else: "Remove owner everywhere"}
              </button>
            </.form>
          </div>
        </div>
        <.health :if={org.status == :ready} organization={org} now={@now} />
        <p :if={org.status == :reauthorization} class="connection-warning">
          Sign in with GitHub and install the app for this owner to restore access.
          Previous personal-token credentials are not used.
        </p>
        <p :if={org.legacy_credential} class="connection-warning" role="alert">
          A previous personal-token credential is retained in the dedicated keychain but is not used.
          Remove this owner to delete that credential explicitly.
        </p>
        <p
          :if={org.status == :disconnected && org.last_error == :keychain}
          class="connection-warning"
          role="alert"
        >
          Disconnected locally. Credential removal failed; retry to delete it from the dedicated keychain.
        </p>
        <.form
          :if={org.status == :ready && @workspace_options != []}
          for={%{}}
          action="/connections/github"
          method="post"
          id={"github-owner-attach-#{org.id}"}
          class="github-connect-form"
        >
          <input type="hidden" name="operation" value="attach" />
          <input type="hidden" name="organization_id" value={org.id} />
          <label for={"github-owner-workspace-#{org.id}"}>Workspace</label>
          <select
            id={"github-owner-workspace-#{org.id}"}
            name="workspace_id"
            class="workspace-name-input"
            required
          >
            <option :for={{name, id} <- @workspace_options} value={id}>{name}</option>
          </select>
          <button type="submit" class="workspace-action workspace-action-primary">Add to workspace</button>
        </.form>
      </article>
      <p :if={@connections != [] && @organizations == []} class="mail-muted">
        No accessible app installations. Install the app on the desired owner, obtain organization approval if required, then refresh app installations.
      </p>
      <details
        id="github-setup-help"
        class="connection-help"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Access, freshness &amp; disconnecting</summary>
        <p class="mail-muted">
          Only repositories selected for accessible GitHub App installations are included, grouped by owner.
          One sign-in can access several installations; each owner can appear in several workspaces.
          LOVELACE never fetches repository contents, comments, avatars or remote images.
          Choose at most 100 repositories per installation; larger selections cannot be refreshed.
          It polls while unlocked and running; sleep, network failures and rate limits delay updates.
          Refresh does not bypass cooldowns. Cached pull requests expire after 24 hours.
        </p>
        <p class="mail-muted">
          Removing an owner or workspace membership does not revoke GitHub authorization.
          Disconnect account removes that account's local memberships, caches and App credentials.
          Retained personal-token credentials remain separately removable on their owner cards.
          Revoke authorization or uninstall separately in GitHub. Tokens stay in the dedicated LOVELACE keychain.
        </p>
      </details>
    </section>
    """
  end

  attr :organizations, :list, required: true
  attr :memberships, :list, required: true
  attr :workspace, :any, required: true
  attr :error, :boolean, required: true
  attr :adding, :boolean, default: false

  def workspace(assigns) do
    ids =
      for member <- assigns.memberships,
          member.workspace_id == assigns.workspace.id,
          do: member.organization_id

    assigns =
      assign(assigns,
        attached: Enum.filter(assigns.organizations, &(&1.id in ids)),
        available: Enum.filter(assigns.organizations, &(&1.status == :ready && &1.id not in ids))
      )

    ~H"""
    <section id="workspace-github" class="workspace-github" aria-labelledby="workspace-github-heading">
      <div class="github-section-heading">
        <h3 id="workspace-github-heading" class="home-eyebrow">GitHub</h3>
        <.link
          :if={@attached != []}
          patch="/connections/github"
          class="workspace-action workspace-action-link"
        >Manage connections</.link>
      </div>
      <p :if={@error} class="connection-warning" role="alert">
        GitHub workspace information is unavailable.
      </p>
      <div :if={!@error && @attached == []} class="empty-state">
        <.icon name="hero-code-bracket" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h4 class="empty-state-title">Add GitHub to this workspace</h4>
          <p class="empty-state-copy">
            {if @available == [],
              do:
                "Connect a GitHub account or organization, then add its repository owner here to see pull requests on Home.",
              else: "Choose an accessible repository owner below to see its pull requests on Home."}
          </p>
          <div :if={@available == []} class="empty-state-actions">
            <.link patch="/connections/github" class="workspace-action workspace-action-primary">
              Connect GitHub
            </.link>
          </div>
        </div>
      </div>
      <article :for={org <- @attached} class="connection-card" id={"workspace-github-#{org.id}"}>
        <div class="github-org-heading">
          <div>
            <h4>{org.login}</h4><p class="mail-muted">Read-only pull requests on Home</p>
          </div>
          <.form for={%{}} action="/connections/github" method="post" id={"github-detach-#{org.id}"}>
            <input type="hidden" name="operation" value="detach" />
            <input type="hidden" name="workspace_id" value={@workspace.id} />
            <input type="hidden" name="organization_id" value={org.id} />
            <button type="submit" class="workspace-action workspace-action-danger">Remove from workspace</button>
          </.form>
        </div>
      </article>
      <details
        :if={!@error && @available != []}
        id={if @adding, do: "github-attach-editor-setup", else: "github-attach-editor"}
        class="connection-help"
        open={@adding}
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary class={["workspace-action", @attached == [] && "workspace-action-primary"]}>
          Add GitHub account / organization
        </summary>
        <.form
          for={%{}}
          action="/connections/github"
          method="post"
          id="github-attach-form"
          class="github-connect-form"
        >
          <input type="hidden" name="operation" value="attach" />
          <input type="hidden" name="workspace_id" value={@workspace.id} />
          <label for="github-existing-organization">Accessible repository owner</label>
          <select
            id="github-existing-organization"
            name="organization_id"
            class="workspace-name-input"
            required
          >
            <option :for={org <- @available} value={org.id}>{org.login}</option>
          </select>
          <button type="submit" class="workspace-action workspace-action-primary">Add to workspace</button>
        </.form>
      </details>
    </section>
    """
  end

  attr :organization, :any, required: true
  attr :now, :any, required: true

  defp health(assigns) do
    assigns = assign(assigns, :expired, expired?(assigns.organization, assigns.now))

    ~H"""
    <div class="github-health" role="status">
      <p :if={@organization.last_error} class="connection-warning">
        {error_label(@organization.last_error)}
      </p>
      <p :if={is_nil(@organization.fetched_at)} class="mail-muted">
        Pull requests not yet available.
      </p>
      <p :if={@expired} class="connection-warning">
        Cached pull requests expired. Refresh to read them again.
      </p>
      <p
        :if={@organization.fetched_at && !@expired}
        class={if stale?(@organization, @now), do: "connection-warning", else: "mail-muted"}
      >
        {if stale?(@organization, @now), do: "Stale · last checked ", else: "Checked "}
        <time datetime={DateTime.to_iso8601(@organization.fetched_at)}>{Calendar.strftime(
          @organization.fetched_at,
          "%b %d, %H:%M UTC"
        )}</time>
      </p>
    </div>
    """
  end

  defp workspace_names(id, memberships, options) do
    ids = for member <- memberships, member.organization_id == id, do: member.workspace_id
    names = for {name, id} <- options, id in ids, do: name
    if names == [], do: "Not attached to a workspace", else: Enum.join(names, " · ")
  end

  defp observed?(org, now), do: not is_nil(org.fetched_at) && not expired?(org, now)
  defp expired?(%{fetched_at: nil}, _), do: false
  defp expired?(org, now), do: DateTime.diff(now, org.fetched_at) >= 86_400

  defp stale?(org, now),
    do: not is_nil(org.last_error) || DateTime.diff(now, org.fetched_at) >= 600

  defp count(prs, :draft), do: Enum.count(prs, & &1["is_draft"])

  defp count(prs, :review),
    do: Enum.count(prs, &(!&1["is_draft"] && &1["review_decision"] == "REVIEW_REQUIRED"))

  defp count(prs, :failed), do: Enum.count(prs, &(&1["checks"] in ["FAILURE", "ERROR"]))
  defp review_label(%{"is_draft" => true}), do: "Draft"
  defp review_label(%{"review_decision" => "APPROVED"}), do: "Approved"
  defp review_label(%{"review_decision" => "CHANGES_REQUESTED"}), do: "Changes requested"
  defp review_label(%{"review_decision" => "REVIEW_REQUIRED"}), do: "Awaiting review"
  defp review_label(_), do: "Review status unavailable"
  defp checks_label("SUCCESS"), do: "Checks passing"
  defp checks_label(value) when value in ["FAILURE", "ERROR"], do: "Checks failing"
  defp checks_label("PENDING"), do: "Checks pending"
  defp checks_label(_), do: "Checks unavailable"

  defp date_label(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> Calendar.strftime(date, "%b %d, %H:%M UTC")
      _ -> "time unavailable"
    end
  end

  defp date_label(_), do: "time unavailable"

  defp owner_label(%{owner_type: :user}), do: "Personal account"
  defp owner_label(_), do: "Organization"

  defp auth_error(:configuration),
    do:
      "GitHub App configuration is invalid or device flow is disabled. Check the public client ID and app settings."

  defp auth_error(:expired), do: "The GitHub authorization code expired. Start sign-in again."

  defp auth_error(:denied),
    do: "GitHub authorization was denied. Start sign-in again if you want to connect."

  defp auth_error(:reconnect),
    do: "GitHub access was rejected. Check app installation access and sign in again."

  defp auth_error(:keychain),
    do:
      "GitHub authorized access, but local credential storage failed. Check the dedicated keychain; do not reset the vault."

  defp auth_error(:rate_limited),
    do: "GitHub rate-limited authorization. Wait before starting sign-in again."

  defp auth_error(_),
    do: "GitHub sign-in could not finish. Check connectivity and app setup, then try again."

  defp error_label(:rate_limited),
    do: "GitHub rate limit reached. Refresh is paused until the cooldown ends."

  defp error_label(:reconnect),
    do: "GitHub access expired or was denied. Sign in again and check app installation access."

  defp error_label(:keychain),
    do: "Dedicated keychain unavailable. Check GitHub setup and vault access."

  defp error_label(_),
    do: "GitHub refresh failed. Previously observed results may be stale; try Refresh."
end
