defmodule LovelaceWeb.GitHubComponents do
  @moduledoc "Read-only GitHub App setup, workspace repository selections and activity readouts."
  use LovelaceWeb, :html

  attr :organizations, :list, required: true
  attr :memberships, :list, required: true
  attr :workspace_options, :list, required: true
  attr :error, :boolean, required: true
  attr :now, :any, required: true
  attr :workspace_id, :string, default: nil

  def dashboard(assigns) do
    assigns =
      assign(assigns, :organizations, scoped_organizations(assigns))

    ~H"""
    <section
      id={if @workspace_id, do: "workspace-github-readouts", else: "github-readouts"}
      class="github-readouts"
      aria-labelledby={
        if @workspace_id, do: "workspace-github-activity-heading", else: "github-home-heading"
      }
    >
      <div class="home-section-heading">
        <h3
          id={if @workspace_id, do: "workspace-github-activity-heading", else: "github-home-heading"}
          class="home-eyebrow"
        >
          GitHub activity
        </h3>
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
            Connect a GitHub account or organization for read-only pull requests, issues and Actions status.
          </p>
          <div class="empty-state-actions">
            <.link patch="/connections/github" class="workspace-action workspace-action-link">
              Connect GitHub
            </.link>
          </div>
        </div>
      </div>
      <article
        :for={org <- @organizations}
        id={"#{if @workspace_id, do: "workspace-", else: ""}github-org-#{org.id}"}
        class="github-organization"
      >
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
        <p :if={Map.get(org, :repository_selection, false)} class="mail-muted">
          Selected workspace repositories only. Shown rows are a subset of the bounded owner snapshot, not repository totals.
        </p>
        <h5 class="github-readout-title">Open pull requests</h5>
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
          No open pull requests found in accessible repositories.
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
                {pr["repository"]} #{pr["number"]} · {pr["author"] || "Author unavailable"}
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
        <.related_activity organization={org} now={@now} />
      </article>
    </section>
    """
  end

  attr :organizations, :list, required: true
  attr :connections, :list, required: true
  attr :auth, :map, required: true
  attr :configured, :boolean, required: true
  attr :configuration_status, :atom, required: true
  attr :installation_url, :string, default: nil
  attr :callback_url, :string, required: true
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
        <span class="mail-muted">Read-only repositories &amp; organizations</span>
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
                "Install your app on the desired accounts, then sign in to authorize read-only access. Organization membership alone does not grant app access.",
              else:
                "Register a GitHub App, save its OAuth client settings here, then sign in. No personal access token or private key is needed."}
          </p>
          <p
            :if={@configuration_status in [:unknown, :loading]}
            class="empty-state-copy"
            role="status"
          >
            Checking local app settings…
          </p>
          <p :if={@configuration_status == :not_connected} class="empty-state-copy" role="status">
            GitHub App setup is required before you can sign in.
          </p>
          <p :if={@configuration_status == :unavailable} class="connection-warning" role="alert">
            App settings could not be read from the dedicated keychain. Unlock LOVELACE and check keychain access; this is not a GitHub authorization failure.
          </p>
          <details
            id="github-app-setup"
            class="connection-help"
            open={!@configured}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary class="workspace-action">GitHub App setup guide</summary>
            <ol class="github-setup-steps">
              <li>
                Open <a
                  href="https://github.com/settings/apps/new"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="workspace-action-link"
                >Register a new GitHub App<span class="sr-only"> (opens GitHub in a new tab)</span></a>,
                not an OAuth App. Choose a unique app name and set Homepage URL to this LOVELACE installation's origin.
              </li>
              <li>
                Set <strong>Callback URL</strong>
                to <code id="github-callback-url">{@callback_url}</code>.
                Leave <strong>Expire user authorization tokens</strong>
                enabled.
                Device flow and authorization during installation are not required.
              </li>
              <li>
                Disable <strong>Webhook → Active</strong>. Under Repository permissions, choose <strong>Pull requests: Read-only</strong>, <strong>Issues: Read-only</strong>,
                <strong>Actions: Read-only</strong>
                and <strong>Checks: Read-only</strong>.
                Metadata is automatic. Leave all other permissions at No access; no writes or repository contents are needed.
              </li>
              <li>
                Choose <strong>Any account</strong>
                for installation if you want organizations or other personal accounts,
                then create the app. Copy its <strong>Client ID</strong>
                (not App ID),
                generate a <strong>client secret</strong>, and copy the slug from <code>github.com/apps/your-app-slug</code>.
              </li>
              <li>
                Save those settings below, then <strong>Install / manage app access</strong>.
                Choose only the repositories you want to read, at most 100 per installation.
                An organization administrator may need to approve installation and permissions.
              </li>
              <li>
                Choose <strong>Sign in with GitHub</strong>, review authorization on GitHub, then return here.
                Add an owner or selected repositories to a workspace. Each workspace keeps its own selection.
              </li>
            </ol>
          </details>
          <details
            id="github-client-editor"
            class="connection-help"
            open={!@configured}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary class="workspace-action">
              {if @configured, do: "Replace app client settings", else: "Add app client settings"}
            </summary>
            <.form
              for={%{}}
              id="github-client-form"
              action="/connections/github"
              method="post"
              autocomplete="off"
              class="github-connect-form"
            >
              <input type="hidden" name="operation" value="save_client" />
              <label for="github-client-id">Client ID</label>
              <input
                id="github-client-id"
                name="client_id"
                type="text"
                class="workspace-name-input"
                required
                maxlength="128"
                autocomplete="off"
                autocapitalize="none"
                spellcheck="false"
                aria-describedby="github-client-hint"
              />
              <label for="github-client-secret">Client secret</label>
              <input
                id="github-client-secret"
                name="client_secret"
                type="password"
                class="workspace-name-input"
                required
                maxlength="1024"
                autocomplete="new-password"
                autocapitalize="none"
                spellcheck="false"
                aria-describedby="github-client-hint"
              />
              <label for="github-app-slug">App URL slug</label>
              <input
                id="github-app-slug"
                name="app_slug"
                type="text"
                class="workspace-name-input"
                required
                maxlength="100"
                pattern="[a-z0-9][a-z0-9-]*"
                autocomplete="off"
                autocapitalize="none"
                spellcheck="false"
                placeholder="your-app-slug"
              />
              <p id="github-client-hint" class="mail-muted">
                Stored in the dedicated LOVELACE keychain. The secret is never shown again.
                Saving is local only: it does not contact GitHub, grant access or require a restart.
                Switching apps requires signing in again; workspace memberships are preserved.
              </p>
              <button type="submit" class="workspace-action workspace-action-primary">Save app settings</button>
            </.form>
          </details>
          <p :if={@configured} id="github-client-status" class="mail-muted" role="status">
            App settings stored locally · GitHub access not verified by saving.
          </p>
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
            :if={@configured && @auth.status not in [:pending, :exchanging]}
            for={%{}}
            id="github-sign-in-form"
            action="/connections/github"
            method="post"
          >
            <input type="hidden" name="operation" value="sign_in" />
            <button type="submit" class="workspace-action workspace-action-primary">Sign in with GitHub</button>
          </.form>
          <div
            :if={@auth.status in [:pending, :exchanging]}
            id="github-browser-authorization"
            role="status"
          >
            <p class="mail-muted">
              Sign-in is waiting for authorization in GitHub. Complete it in the browser before it expires, or cancel and start again.
            </p>
            <.form for={%{}} id="github-cancel-sign-in" action="/connections/github" method="post">
              <input type="hidden" name="operation" value="cancel_sign_in" />
              <button type="submit" class="workspace-action">Cancel sign-in</button>
            </.form>
          </div>
          <p :if={@auth.status == :connected} id="github-authorized" class="mail-muted" role="status">
            GitHub sign-in complete. Add an accessible owner or selected repositories to a workspace below.
          </p>
          <p
            :if={@auth.status == :failed}
            id="github-authorization-error"
            class="connection-warning"
            role="alert"
          >
            GitHub sign-in could not finish. Check app settings, installation access and connectivity, then start sign-in again.
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
          <button type="submit" class="workspace-action workspace-action-primary">Add whole owner to workspace</button>
        </.form>
        <.repository_picker
          :if={org.status == :ready && @workspace_options != []}
          organization={org}
          workspace_options={@workspace_options}
        />
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
          One sign-in can access several installations; each owner or repository selection can appear in several workspaces.
          LOVELACE never fetches repository contents, comments, workflow logs, artifacts, avatars or remote images.
          Choose at most 100 repositories per installation; larger selections cannot be refreshed.
          It polls while unlocked and running; sleep, network failures and rate limits delay updates.
          Refresh does not bypass cooldowns. Cached activity expires after 24 hours.
        </p>
        <p class="mail-muted">
          Missing an organization? Both your GitHub user and the installed app need access.
          Check organization approval and selected repositories; for SAML SSO, start an active organization SSO session before signing in again.
          After adding permissions, approve them on each installation and refresh app installations.
          A callback mismatch requires the exact scheme, hostname, port and path shown in the setup guide.
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
  attr :now, :any, required: true

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
                "Connect GitHub, then add an owner or selected repositories for pull requests, issues and Actions status.",
              else:
                "Add a whole owner or choose specific repositories below. Connections can be reused across workspaces."}
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
            <h4>{org.login}</h4>
            <p class="mail-muted">{selection_label(org.id, @memberships, @workspace.id)}</p>
          </div>
          <.form for={%{}} action="/connections/github" method="post" id={"github-detach-#{org.id}"}>
            <input type="hidden" name="operation" value="detach" />
            <input type="hidden" name="workspace_id" value={@workspace.id} />
            <input type="hidden" name="organization_id" value={org.id} />
            <button type="submit" class="workspace-action workspace-action-danger">Remove from workspace</button>
          </.form>
        </div>
        <.repository_picker
          :if={org.status == :ready}
          organization={org}
          workspace_id={@workspace.id}
          selected={selection(org.id, @memberships, @workspace.id)}
        />
        <.form
          :if={selection(org.id, @memberships, @workspace.id) != [] && org.status == :ready}
          for={%{}}
          action="/connections/github"
          method="post"
          id={"github-whole-owner-#{org.id}"}
        >
          <input type="hidden" name="operation" value="attach" />
          <input type="hidden" name="workspace_id" value={@workspace.id} />
          <input type="hidden" name="organization_id" value={org.id} />
          <button type="submit" class="workspace-action">Use whole owner instead</button>
        </.form>
      </article>
      <details
        :if={!@error && @available != []}
        id={if @adding, do: "github-attach-editor-setup", else: "github-attach-editor"}
        class="connection-help"
        open={@adding}
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary class={["workspace-action", @attached == [] && "workspace-action-primary"]}>
          Add GitHub owner / repositories
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
          <button type="submit" class="workspace-action workspace-action-primary">Add whole owner</button>
        </.form>
        <.repository_picker :for={org <- @available} organization={org} workspace_id={@workspace.id} />
      </details>
      <.dashboard
        :if={!@adding && @attached != []}
        organizations={@organizations}
        memberships={@memberships}
        workspace_options={[]}
        workspace_id={@workspace.id}
        error={@error}
        now={@now}
      />
    </section>
    """
  end

  attr :organization, :any, required: true
  attr :workspace_id, :string, default: nil
  attr :workspace_options, :list, default: []
  attr :selected, :list, default: []

  defp repository_picker(assigns) do
    ~H"""
    <details
      id={"github-repositories-#{@organization.id}"}
      class="connection-help"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary class="workspace-action">Choose repositories from {@organization.login}</summary>
      <p :if={@organization.repositories == []} class="mail-muted">
        Repository choices are not available yet. Refresh this owner in Connections, then return here.
      </p>
      <.form
        :if={@organization.repositories != []}
        for={%{}}
        action="/connections/github"
        method="post"
        id={"github-repository-form-#{@organization.id}"}
        class="github-connect-form"
      >
        <input type="hidden" name="operation" value="attach_repositories" />
        <input type="hidden" name="organization_id" value={@organization.id} />
        <input :if={@workspace_id} type="hidden" name="workspace_id" value={@workspace_id} />
        <label :if={!@workspace_id} for={"github-repository-workspace-#{@organization.id}"}>Workspace</label>
        <select
          :if={!@workspace_id}
          id={"github-repository-workspace-#{@organization.id}"}
          name="workspace_id"
          class="workspace-name-input"
          required
        >
          <option :for={{name, id} <- @workspace_options} value={id}>{name}</option>
        </select>
        <fieldset class="github-repository-choices">
          <legend>Selected repositories</legend>
          <label :for={repo <- @organization.repositories}>
            <input
              type="checkbox"
              name="repository_ids[]"
              value={repo["id"]}
              checked={repo["id"] in @selected}
            />
            <span>{repo["full_name"]}</span>
          </label>
        </fieldset>
        <p class="mail-muted">
          Choose at least one. Saving replaces this owner's selection in this workspace only; other workspaces and GitHub permissions do not change.
        </p>
        <button type="submit" class="workspace-action workspace-action-primary">Save repository selection</button>
      </.form>
    </details>
    """
  end

  attr :organization, :any, required: true
  attr :now, :any, required: true

  defp related_activity(assigns) do
    ~H"""
    <div :if={observed?(@organization, @now)} class="github-related-activity">
      <h5 class="github-readout-title">Open issues</h5>
      <p class="github-summary">
        {length(@organization.issues)} shown<span :if={@organization.issue_count != nil}> · {@organization.issue_count} open in accessible repositories</span>
      </p>
      <p :if={@organization.issues_truncated} class="connection-warning">
        Partial issues · some repositories, details or totals are unavailable.
      </p>
      <p
        :if={
          @organization.issues == [] && @organization.issue_count == 0 &&
            !@organization.issues_truncated
        }
        class="mail-muted"
      >
        No open issues found in accessible repositories.
      </p>
      <p
        :if={
          @organization.issues == [] &&
            (@organization.issue_count != 0 || @organization.issues_truncated)
        }
        class="mail-muted"
      >
        Issue details unavailable in this snapshot. Check Issues read-only permission and repository access.
      </p>
      <ul class="github-pr-list">
        <li :for={issue <- @organization.issues} class="github-pr github-issue">
          <div class="github-pr-main">
            <a
              href={issue["url"]}
              target="_blank"
              rel="noopener noreferrer"
              class="github-pr-title workspace-action-link"
            >{issue["title"]}<span class="sr-only"> (opens GitHub in a new tab)</span></a>
            <p class="github-pr-meta">
              {issue["repository"]} #{issue["number"]} · {issue["author"] || "Author unavailable"}
            </p>
          </div>
          <div class="github-pr-state">
            <time datetime={issue["updated_at"]}>Updated {date_label(issue["updated_at"])}</time>
          </div>
        </li>
      </ul>
      <h5 class="github-readout-title">Recent Actions runs</h5>
      <p class="mail-muted">
        Recent runs, not a combined repository health verdict. At most 10 repositories are checked per owner snapshot.
      </p>
      <p :if={@organization.actions_truncated} class="connection-warning">
        Partial Actions · some repositories or runs are unavailable. Check Actions read-only permission.
      </p>
      <p
        :if={@organization.workflow_runs == [] && !@organization.actions_truncated}
        class="mail-muted"
      >
        No recent workflow runs found in accessible repositories.
      </p>
      <p :if={@organization.workflow_runs == [] && @organization.actions_truncated} class="mail-muted">
        Workflow run details unavailable in this snapshot.
      </p>
      <ul class="github-pr-list">
        <li :for={run <- @organization.workflow_runs} class="github-pr github-workflow-run">
          <div class="github-pr-main">
            <a
              href={run["url"]}
              target="_blank"
              rel="noopener noreferrer"
              class="github-pr-title workspace-action-link"
            >{run["name"]}<span class="sr-only"> (opens GitHub in a new tab)</span></a>
            <p class="github-pr-meta">{run["repository"]}</p>
          </div>
          <div class="github-pr-state">
            <span class={
              if run["conclusion"] in ["failure", "timed_out", "action_required"],
                do: "github-check-failed"
            }>{run_label(run)}</span>
            <time datetime={run["updated_at"]}>Updated {date_label(run["updated_at"])}</time>
          </div>
        </li>
      </ul>
    </div>
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
        GitHub activity not yet available.
      </p>
      <p :if={@expired} class="connection-warning">
        Cached GitHub activity expired. Refresh to read it again.
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

  defp scoped_organizations(assigns) do
    ready = Enum.filter(assigns.organizations, &(&1.status == :ready))

    if assigns.workspace_id do
      memberships = Enum.filter(assigns.memberships, &(&1.workspace_id == assigns.workspace_id))

      for org <- ready,
          member <- memberships,
          member.organization_id == org.id,
          do: scoped_snapshot(org, member.repository_ids)
    else
      ready
    end
  end

  defp scoped_snapshot(org, []), do: org

  defp scoped_snapshot(org, ids) do
    org
    |> Map.put(:repository_selection, true)
    |> Map.put(:pull_requests, selected_rows(org.pull_requests, ids))
    |> Map.put(:issues, selected_rows(org.issues, ids))
    |> Map.put(:workflow_runs, selected_rows(org.workflow_runs, ids))
    |> Map.put(:total_count, nil)
    |> Map.put(:issue_count, nil)
    |> Map.put(:truncated, true)
    |> Map.put(:issues_truncated, true)
    |> Map.put(:actions_truncated, true)
  end

  defp selected_rows(rows, ids), do: Enum.filter(rows, &(&1["repository_id"] in ids))

  defp selection(org_id, memberships, workspace_id) do
    case Enum.find(
           memberships,
           &(&1.organization_id == org_id && &1.workspace_id == workspace_id)
         ) do
      nil -> []
      member -> member.repository_ids
    end
  end

  defp selection_label(org_id, memberships, workspace_id) do
    case selection(org_id, memberships, workspace_id) do
      [] -> "Whole owner · all repositories accessible to this app"
      ids -> "#{length(ids)} selected repositories · this workspace only"
    end
  end

  @run_conclusions %{
    "success" => "Succeeded",
    "failure" => "Failed",
    "cancelled" => "Cancelled",
    "timed_out" => "Timed out",
    "skipped" => "Skipped",
    "neutral" => "Neutral",
    "action_required" => "Action required",
    "stale" => "Stale",
    "startup_failure" => "Startup failed"
  }

  defp run_label(%{"status" => "completed", "conclusion" => conclusion}),
    do: Map.get(@run_conclusions, conclusion, "Conclusion unavailable")

  defp run_label(%{"status" => "in_progress"}), do: "In progress"

  defp run_label(%{"status" => status})
       when status in ["queued", "requested", "waiting", "pending"],
       do: "Waiting"

  defp run_label(_), do: "Status unavailable"

  defp workspace_names(id, memberships, options) do
    ids = for member <- memberships, member.organization_id == id, do: member.workspace_id
    names = for {name, id} <- options, id in ids, do: name

    if names == [],
      do: if(ids == [], do: "Not attached to a workspace", else: "Workspace activity"),
      else: Enum.join(names, " · ")
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

  defp error_label(:rate_limited),
    do: "GitHub rate limit reached. Refresh is paused until the cooldown ends."

  defp error_label(:reconnect),
    do: "GitHub access expired or was denied. Sign in again and check app installation access."

  defp error_label(:keychain),
    do: "Dedicated keychain unavailable. Check GitHub setup and vault access."

  defp error_label(_),
    do: "GitHub refresh failed. Previously observed results may be stale; try Refresh."
end
