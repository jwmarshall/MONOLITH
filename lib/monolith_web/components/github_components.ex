defmodule MonolithWeb.GitHubComponents do
  @moduledoc "Read-only GitHub App setup, workspace repository selections and activity readouts."
  use MonolithWeb, :html

  attr :organizations, :list, required: true
  attr :memberships, :list, required: true
  attr :workspace_options, :list, required: true
  attr :error, :boolean, required: true
  attr :now, :any, required: true
  attr :workspace_id, :string, default: nil
  attr :activity, :boolean, default: false

  def dashboard(assigns) do
    assigns =
      assign(assigns, :organizations, scoped_organizations(assigns))

    ~H"""
    <section
      id={if @workspace_id, do: "workspace-github-readouts", else: "github-readouts"}
      class="github-readouts"
      aria-labelledby={
        if @activity,
          do: "github-activity-title",
          else:
            if(@workspace_id, do: "workspace-github-activity-heading", else: "github-home-heading")
      }
    >
      <div :if={!@activity} class="home-section-heading">
        <h3
          id={if @workspace_id, do: "workspace-github-activity-heading", else: "github-home-heading"}
          class="home-eyebrow"
        >
          03 / GitHub
        </h3>
      </div>
      <p :if={@error} class="connection-warning" role="alert">
        GitHub information is unavailable. Your connections have not been changed.
      </p>
      <div :if={!@error && @organizations == []} class="empty-state">
        <.icon name="hero-code-bracket" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h4 class="empty-state-title">Connect GitHub</h4>
          <p class="empty-state-copy">Pull requests, issues and recent runs, by owner.</p>
          <div class="empty-state-actions">
            <.link patch="/connections/github" class="workspace-action workspace-action-link">
              Set up GitHub
            </.link>
          </div>
        </div>
      </div>
      <div class={[
        !@activity && "github-home-grid",
        !@activity && !@workspace_id && "github-home-repository-grid"
      ]}>
        <article
          :for={org <- @organizations}
          id={"#{if @workspace_id, do: "workspace-", else: ""}github-org-#{org.id}"}
          class={["github-organization", !@activity && "github-home-organization"]}
        >
          <.home_owner_heading
            :if={!@activity && !@workspace_id}
            organization={org}
            memberships={@memberships}
            workspace_options={@workspace_options}
            now={@now}
          />
          <div :if={!@activity && @workspace_id} class="github-org-heading">
            <div>
              <h4>{org.login}</h4>
              <p class="mail-muted">
                {workspace_names(org.id, @memberships, @workspace_options)}
              </p>
            </div>
          </div>
          <.health :if={@activity} organization={org} now={@now} />
          <.home_repositories :if={!@activity && !@workspace_id} organization={org} now={@now} />
          <.home_snapshot :if={!@activity && @workspace_id} organization={org} now={@now} />
          <.link
            :if={@workspace_id && !@activity}
            patch={MonolithWeb.HomeNavigation.github_activity_path(@workspace_id, org.id)}
            class="workspace-action workspace-action-link"
            aria-label={"View #{org.login} activity"}
          >View activity</.link>
          <div :if={@activity} class="github-activity-sections">
            <p class="github-snapshot-context mail-muted">
              {if Map.get(org, :repository_selection, false),
                do:
                  "Selected workspace repositories only. Shown rows are a subset of the bounded owner snapshot, not repository totals.",
                else: "Bounded installation snapshot. Shown rows are not complete repository totals."}
            </p>
            <section class="github-review-section" aria-labelledby={"github-pr-heading-#{org.id}"}>
              <div class="github-review-heading">
                <h2 id={"github-pr-heading-#{org.id}"} class="github-readout-title">Pull requests</h2>
                <span class="github-section-count">
                  {snapshot_size(org, @now, :pull_requests)} in snapshot
                </span>
              </div>
              <p :if={observed?(org, @now)} class="github-summary">
                {length(org.pull_requests)} shown<span :if={
                  org.total_count != nil && !Map.get(org, :repository_selection, false)
                }> · {org.total_count} open in accessible repositories</span>
                <span :if={count(org.pull_requests, :review) > 0}> · {count(
                  org.pull_requests,
                  :review
                )} awaiting review</span>
                <span :if={count(org.pull_requests, :failed) > 0}> · {count(
                  org.pull_requests,
                  :failed
                )} with failing checks</span>
                <span :if={count(org.pull_requests, :draft) > 0}> · {count(org.pull_requests, :draft)} draft</span>
              </p>
              <p :if={org.truncated && observed?(org, @now)} class="connection-warning">
                Partial results · some pull requests or status fields may be unavailable. Most recently updated first.
              </p>
              <p
                :if={
                  observed?(org, @now) && org.pull_requests == [] && org.total_count == 0 &&
                    !org.truncated
                }
                class="mail-muted"
              >
                No open pull requests found in accessible repositories.
              </p>
              <p
                :if={
                  observed?(org, @now) && org.pull_requests == [] &&
                    (org.total_count != 0 || org.truncated)
                }
                class="mail-muted"
              >
                {if Map.get(org, :repository_selection, false),
                  do:
                    "No pull requests match this workspace selection in the bounded owner snapshot.",
                  else: "Pull request details are unavailable in these partial results."}
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
                    <.status_signal
                      id={"github-review-#{org.id}-#{pr["repository_id"]}-#{pr["number"]}"}
                      state={review_signal(pr)}
                      label={review_label(pr)}
                    />
                    <span class={if pr["checks"] in ["FAILURE", "ERROR"], do: "github-check-failed"}>
                      <.status_signal
                        id={"github-checks-#{org.id}-#{pr["repository_id"]}-#{pr["number"]}"}
                        state={checks_signal(pr["checks"])}
                        label={checks_label(pr["checks"])}
                      />
                    </span>
                    <time datetime={pr["updated_at"]}>Updated {date_label(pr["updated_at"])}</time>
                  </div>
                </li>
              </ul>
            </section>
            <.related_activity organization={org} now={@now} />
          </div>
        </article>
      </div>
    </section>
    """
  end

  attr :organization, :any, required: true
  attr :now, :any, required: true

  defp home_repositories(assigns) do
    org = assigns.organization

    grouped =
      Map.new([:pull_requests, :issues, :workflow_runs], fn kind ->
        {kind, Enum.group_by(Map.fetch!(org, kind), & &1["repository_id"])}
      end)

    repositories =
      org
      |> Map.get(:repositories, [])
      |> Enum.sort_by(& &1["full_name"])
      |> Enum.map(fn repository ->
        snapshot =
          Enum.reduce(grouped, org, fn {kind, rows}, snapshot ->
            Map.put(snapshot, kind, Map.get(rows, repository["id"], []))
          end)

        %{id: repository["id"], name: repository["full_name"], snapshot: snapshot}
      end)

    assigns = assign(assigns, :repositories, repositories)

    ~H"""
    <div
      id={"github-home-repositories-#{@organization.id}"}
      class="github-home-repository-disclosure"
      hidden
      phx-mounted={JS.ignore_attributes("hidden")}
    >
      <ul
        :if={@repositories != []}
        class="github-home-repositories"
        aria-label={@organization.login <> " repositories"}
      >
        <li
          :for={repository <- @repositories}
          class="github-home-repository"
          data-repository-id={repository.id}
        >
          <h5 class="github-home-repository-name"><bdi>{repository.name}</bdi></h5>
          <.home_snapshot organization={repository.snapshot} now={@now} />
        </li>
      </ul>
      <div :if={@repositories == []} class="github-home-repository-empty">
        <p class="mail-muted">
          {if observed?(@organization, @now),
            do: "No repositories listed in this snapshot",
            else: "Repository list unavailable"}
        </p>
      </div>
    </div>
    """
  end

  attr :organization, :any, required: true
  attr :now, :any, required: true

  defp home_snapshot(assigns) do
    assigns =
      assign(
        assigns,
        home_metrics(assigns.organization, observed?(assigns.organization, assigns.now))
      )

    ~H"""
    <dl class="github-home-metrics" aria-label="Bounded installation snapshot">
      <.snapshot_count label="PRS" total={@prs} paired attention={@prs_attention} />
      <.snapshot_count label="ISSUES" total={@issues} />
      <.snapshot_count
        label="RUNS"
        total={@runs}
        paired
        attention={@runs_attention}
        attention_label="FAILED"
        failure
      />
    </dl>
    """
  end

  defp home_metrics(_org, false),
    do: %{prs: nil, issues: nil, prs_attention: nil, runs: nil, runs_attention: nil}

  defp home_metrics(org, true) do
    prs_available = org.pull_requests != [] || !org.truncated
    runs_available = org.workflow_runs != [] || !org.actions_truncated

    %{
      prs: if(prs_available, do: length(org.pull_requests)),
      issues: if(org.issues != [] || !org.issues_truncated, do: length(org.issues)),
      prs_attention:
        if prs_available do
          pr_attention_count(org.pull_requests)
        end,
      runs: if(runs_available, do: length(org.workflow_runs)),
      runs_attention:
        if runs_available do
          Enum.count(
            org.workflow_runs,
            &(&1["conclusion"] in ["failure", "timed_out", "action_required", "startup_failure"])
          )
        end
    }
  end

  defp pr_attention_count(prs) do
    Enum.reduce_while(prs, 0, fn pr, count ->
      cond do
        (!pr["is_draft"] && pr["review_decision"] == "REVIEW_REQUIRED") ||
            pr["checks"] in ["FAILURE", "ERROR"] ->
          {:cont, count + 1}

        (pr["is_draft"] || pr["review_decision"] in ["APPROVED", "CHANGES_REQUESTED"]) &&
            pr["checks"] in ["SUCCESS", "PENDING"] ->
          {:cont, count}

        true ->
          {:halt, nil}
      end
    end)
  end

  attr :label, :string, required: true
  attr :total, :any, required: true
  attr :paired, :boolean, default: false
  attr :attention, :any, default: nil
  attr :attention_label, :string, default: "ATTENTION"
  attr :failure, :boolean, default: false

  defp snapshot_count(assigns) do
    assigns =
      assign(assigns,
        value: if(is_integer(assigns.total), do: assigns.total, else: "—"),
        attention_value: if(is_integer(assigns.attention), do: assigns.attention, else: "—")
      )

    ~H"""
    <div class="github-home-metric">
      <dt class="metric-label">{@label}<span :if={@paired}> / {@attention_label}</span></dt>
      <dd class="github-home-number">
        <span aria-hidden="true">
          <span class="github-home-total">{@value}</span><span
            :if={@paired}
            class="github-home-separator"
          > / </span><span
            :if={@paired}
            class={["github-home-attention", @failure && "github-home-failure"]}
            title={"#{@attention_label} in the snapshot"}
          >{@attention_value}</span>
        </span>
        <span class="sr-only">
          {@label} in snapshot: {if is_integer(@total), do: @total, else: "unavailable"}<span :if={
            @paired
          }>; {@attention_label} in snapshot: {if is_integer(@attention),
            do: @attention,
            else: "unavailable"}</span>
        </span>
      </dd>
    </div>
    """
  end

  attr :organization, :any, required: true
  attr :memberships, :list, required: true
  attr :workspace_options, :list, required: true
  attr :now, :any, required: true

  defp home_owner_heading(assigns) do
    assigns = assign(assigns, :workspaces, owner_workspaces(assigns))

    ~H"""
    <div class="github-org-heading github-home-owner-heading">
      <div>
        <h4>
          <button
            id={"github-home-toggle-#{@organization.id}"}
            type="button"
            class="github-home-owner-toggle"
            aria-expanded="false"
            aria-controls={"github-home-repositories-#{@organization.id}"}
            phx-mounted={JS.ignore_attributes("aria-expanded")}
            phx-click={
              JS.toggle_attribute({"hidden", ""},
                to: "#github-home-repositories-#{@organization.id}"
              )
              |> JS.toggle_attribute({"aria-expanded", "true", "false"})
            }
          >
            <.icon name="hero-chevron-right" class="github-home-owner-chevron size-4" />
            <span><bdi>{@organization.login}</bdi><span class="sr-only"> repositories</span></span>
          </button>
        </h4>
        <p class="github-home-workspaces mail-muted">
          <span :for={{name, _id} <- @workspaces}><bdi>{name}</bdi></span>
          <span :if={@workspaces == []}>Not in a workspace</span>
        </p>
        <.link
          :if={@workspaces == []}
          patch="/connections/github"
          class="github-home-setup workspace-action workspace-action-link"
          aria-label={"Add #{@organization.login} to a workspace"}
        >Add to workspace</.link>
      </div>
      <.home_snapshot organization={@organization} now={@now} />
    </div>
    """
  end

  attr :organization, :any, required: true
  attr :memberships, :list, required: true
  attr :workspace_options, :list, required: true

  defp connection_activity_links(assigns) do
    workspaces = owner_workspaces(assigns)
    assigns = assign(assigns, workspaces: workspaces, single: length(workspaces) == 1)

    ~H"""
    <div class="github-connection-links">
      <.link
        :for={{name, id} <- @workspaces}
        patch={MonolithWeb.HomeNavigation.github_activity_path(id, @organization.id)}
        class="workspace-action workspace-action-link"
        aria-label={"View #{@organization.login} activity in #{name}"}
      >{if @single, do: "View activity", else: name}</.link>
      <.link
        :if={@workspaces == []}
        patch="/connections/github"
        class="workspace-action workspace-action-link"
        aria-label={"Add #{@organization.login} to a workspace"}
      >Add to workspace</.link>
    </div>
    """
  end

  defp owner_workspaces(assigns) do
    ids =
      for member <- assigns.memberships,
          member.organization_id == assigns.organization.id,
          do: member.workspace_id

    for {name, id} <- assigns.workspace_options, id in ids, do: {name, id}
  end

  attr :organizations, :list, required: true
  attr :memberships, :list, required: true
  attr :workspace, :any, required: true
  attr :organization_id, :string, required: true
  attr :error, :boolean, required: true
  attr :now, :any, required: true

  def activity(assigns) do
    organizations =
      Enum.filter(assigns.organizations, fn organization ->
        organization.id == assigns.organization_id && organization.status == :ready &&
          Enum.any?(assigns.memberships, fn member ->
            member.workspace_id == assigns.workspace.id &&
              member.organization_id == organization.id
          end)
      end)

    repository_names =
      for organization <- organizations,
          member <- assigns.memberships,
          member.workspace_id == assigns.workspace.id,
          member.organization_id == organization.id,
          repository <- Map.get(organization, :repositories, []),
          member.repository_ids == [] || repository["id"] in member.repository_ids,
          do: repository["full_name"]

    assigns = assign(assigns, organizations: organizations, repository_names: repository_names)

    ~H"""
    <section
      id="github-owner-activity"
      class="github-owner-activity"
      aria-labelledby="github-activity-title"
    >
      <header class="github-activity-heading">
        <div class="github-section-heading page-header-row">
          <p class="home-eyebrow">03 / GitHub · {@workspace.name}</p>
          <.link
            patch={MonolithWeb.HomeNavigation.workspace_path(@workspace.id)}
            class="workspace-action workspace-action-link"
          >Back to workspace</.link>
          <.lock_control />
        </div>
        <div class="github-owner-heading">
          <h1 id="github-activity-title" tabindex="-1" data-workspace-heading>
            {case @organizations do
              [organization] -> organization.login
              _ -> "GitHub activity unavailable"
            end}
          </h1>
          <button
            :for={organization <- @organizations}
            type="button"
            class="workspace-action"
            phx-click="github:refresh"
            phx-value-id={organization.id}
          >
            Refresh<span class="sr-only">{organization.login} activity</span>
          </button>
        </div>
        <p class="mail-muted">Selected workspace snapshot · all timestamps UTC</p>
        <p :if={@repository_names != []} class="github-pr-meta">
          {Enum.join(@repository_names, " · ")}
        </p>
      </header>
      <div class="github-activity-body">
        <p :if={!@error && @organizations == []} class="connection-warning" role="alert">
          This installation owner is no longer available in this workspace. Review its connections.
        </p>
        <.dashboard
          :if={@error || @organizations != []}
          organizations={@organizations}
          memberships={@memberships}
          workspace_options={[{@workspace.name, @workspace.id}]}
          workspace_id={@workspace.id}
          activity
          error={@error}
          now={@now}
        />
      </div>
    </section>
    """
  end

  attr :organizations, :list, required: true
  attr :connections, :list, required: true
  attr :auth, :map, required: true
  attr :authorization_error, :string, default: nil
  attr :configured, :boolean, required: true
  attr :configuration_status, :atom, required: true
  attr :installation_url, :string, default: nil
  attr :memberships, :list, required: true
  attr :workspace_options, :list, required: true
  attr :error, :boolean, required: true
  attr :now, :any, required: true

  def connections(assigns) do
    assigns = assign(assigns, :connected, Enum.any?(assigns.connections, &(&1.status == :ready)))

    assigns =
      assign(
        assigns,
        :authorization_message,
        assigns.authorization_error ||
          if(assigns.auth.status == :failed,
            do:
              "The GitHub connection could not finish. No new account was connected. Start again below."
          )
      )

    ~H"""
    <section
      id="github-connections"
      class="github-connections"
      aria-label="GitHub connections"
    >
      <div class="github-account-plane">
        <header class="card-section-heading github-provider-heading">
          <p class="mail-eyebrow">GitHub App</p>
          <h3 id="github-connections-heading">GitHub accounts</h3>
          <p class="mail-muted" role="status">
            <.status_signal
              id="github-app-configuration-signal"
              state={
                cond do
                  @configuration_status == :loading -> :active
                  @configuration_status in [:locked, :unavailable] -> :warning
                  @configured -> :ready
                  true -> :unknown
                end
              }
              label={
                cond do
                  @configuration_status in [:unknown, :loading] -> "Checking settings"
                  @configuration_status in [:locked, :unavailable] -> "Settings unavailable"
                  @configured -> "App configured"
                  true -> "Not configured"
                end
              }
            />
          </p>
        </header>
        <div
          :if={@configuration_status not in [:unknown, :loading, :locked, :unavailable]}
          class="github-client-settings"
        >
          <MonolithWeb.ModalComponents.credential_modal
            id="github-client-editor"
            title="GitHub App client settings"
            trigger={
              if @configured, do: "Replace app client settings", else: "Add app client settings"
            }
            primary={!@configured}
            form_id="github-client-form"
            action="/connections/github"
            initial_focus="#github-client-id"
            save="Save app settings"
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
            <label for="github-app-slug">App URL or slug</label>
            <input
              id="github-app-slug"
              name="app_slug"
              type="text"
              class="workspace-name-input"
              required
              maxlength="125"
              autocomplete="off"
              autocapitalize="none"
              spellcheck="false"
              placeholder="https://github.com/apps/your-app-slug"
              aria-describedby="github-app-slug-hint"
            />
            <p id="github-app-slug-hint" class="mail-muted">
              Paste the full https://github.com/apps/ URL or just its lowercase slug.
            </p>
            <p id="github-client-hint" class="mail-muted">
              Stored in the dedicated MONOLITH keychain. The secret is never shown again.
              Saving is local only: it does not contact GitHub, grant access or require a restart.
              Switching apps requires signing in again; workspace memberships are preserved.
            </p>
          </MonolithWeb.ModalComponents.credential_modal>
          <p :if={@configured} id="github-client-status" class="mail-muted" role="status">
            App settings saved locally · this alone does not connect a GitHub account.
          </p>
        </div>
        <p :if={@error} class="github-state-message connection-warning" role="alert">
          GitHub connections could not be loaded. Try reloading.
        </p>
        <div
          :if={
            !@connected || !@configured || @auth.status in [:pending, :exchanging, :failed] ||
              @authorization_message
          }
          id="github-authorization"
          class="github-authorization"
        >
          <div class="github-authorization-body">
            <p class="mail-muted">
              <%= cond do %>
                <% @connected -> %>
                  GitHub connected
                <% @configured -> %>
                  Connect your GitHub account
                <% @configuration_status in [:unknown, :loading] -> %>
                  GitHub
                <% @configuration_status in [:locked, :unavailable] -> %>
                  GitHub App settings unavailable
                <% true -> %>
                  Set up GitHub
              <% end %>
            </p>
            <p
              :if={@configuration_status not in [:unknown, :loading, :locked, :unavailable]}
              class="empty-state-copy"
            >
              <%= cond do %>
                <% @connected -> %>
                  Your authorized accounts are listed below. Add their repository owners to a workspace, or connect another account.
                <% @configured -> %>
                  App settings are saved. Choose which repositories the app may read on GitHub, then connect your account to MONOLITH. These are separate steps.
                <% true -> %>
                  Register a GitHub App, save its OAuth client settings here, then sign in. No personal access token or private key is needed.
              <% end %>
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
            <p
              :if={@configuration_status in [:locked, :unavailable]}
              class="connection-warning"
              role="alert"
            >
              App settings could not be read from the dedicated keychain. Unlock MONOLITH and check keychain access; this is not a GitHub authorization failure.
            </p>
            <p
              :if={@authorization_message}
              id="github-authorization-error"
              class="connection-warning"
              role="alert"
            >
              {@authorization_message}
            </p>
            <a
              :if={@configured && @installation_url}
              id="github-install-app"
              href={@installation_url}
              target="_blank"
              rel="noopener noreferrer"
              class="workspace-action workspace-action-link"
            >
              Choose repositories on GitHub<span class="sr-only"> (opens GitHub in a new tab)</span>
            </a>
            <.form
              :if={@configured && @auth.status != :exchanging}
              for={%{}}
              id="github-sign-in-form"
              action="/connections/github"
              method="post"
            >
              <input type="hidden" name="operation" value="sign_in" />
              <button type="submit" class="workspace-action workspace-action-primary">
                <%= cond do %>
                  <% @authorization_message || @auth.status in [:pending, :failed] -> %>
                    Start connection again
                  <% @connected -> %>
                    Connect another account
                  <% true -> %>
                    Connect GitHub account
                <% end %>
              </button>
            </.form>
            <div
              :if={@auth.status in [:pending, :exchanging] && !@authorization_message}
              id="github-browser-authorization"
              role="status"
            >
              <p :if={@auth.status == :pending} class="mail-muted">
                Not connected yet. Approve the app on GitHub to finish connecting to MONOLITH.
                If GitHub already returned you here without connecting, start the connection again.
              </p>
              <p :if={@auth.status == :exchanging} class="mail-muted">
                Finishing connection… MONOLITH is checking GitHub access and saving the account.
              </p>
              <.form for={%{}} id="github-cancel-sign-in" action="/connections/github" method="post">
                <input type="hidden" name="operation" value="cancel_sign_in" />
                <button type="submit" class="workspace-action">Cancel connection attempt</button>
              </.form>
            </div>
          </div>
        </div>
        <div :if={@connections != []} class="github-authorized-accounts">
          <article
            :for={connection <- @connections}
            :if={connection.status != :disconnected || connection.last_error == :keychain}
            id={"github-account-#{connection.id}"}
            class="connection-card"
          >
            <div class="connection-card-head">
              <div>
                <h3 class="github-register-title">{connection.login}</h3>
                <p class="identity mail-muted">
                  Read-only GitHub App account authorization · saved locally
                </p>
              </div>
              <span id={"github-account-status-#{connection.id}"} role="status">
                <.status_signal
                  id={"github-account-connected-#{connection.id}"}
                  state={
                    cond do
                      connection.status == :ready -> :ready
                      connection.status == :disconnected -> :offline
                      true -> :warning
                    end
                  }
                  label={
                    cond do
                      connection.status == :ready -> "Connected"
                      connection.status == :disconnected -> "Disconnected locally"
                      true -> "Sign-in required"
                    end
                  }
                />
              </span>
            </div>
            <div class="github-account-body">
              <p :if={connection.status in [:reauthorization, :refreshing]} class="connection-warning">
                Connect this account again to restore its access.
              </p>
              <p :if={connection.status == :disconnected} class="connection-warning" role="alert">
                Disconnected locally. Credential removal failed; retry to remove it from the dedicated keychain.
              </p>
              <p
                :if={connection.discovery_status}
                id={"github-discovery-status-#{connection.id}"}
                role="status"
                class="mail-muted"
                data-operation-id={connection.discovery_id}
                data-job-id={connection.discovery_job_id}
                data-state={connection.discovery_status}
              >
                {discovery_label(connection.discovery_status)}
                <span :if={connection.discovery_error}>
                  {error_label(connection.discovery_error)}
                </span>
              </p>
            </div>
            <div class="mail-actions">
              <a
                :if={connection.status == :ready && @installation_url}
                href={@installation_url}
                target="_blank"
                rel="noopener noreferrer"
                class="workspace-action"
              >
                Choose repositories on GitHub<span class="sr-only"> (opens GitHub in a new tab)</span>
              </a>
              <.form
                :if={connection.status == :ready}
                for={%{}}
                id={"github-discover-#{connection.id}"}
                action="/connections/github"
                method="post"
              >
                <input type="hidden" name="operation" value="discover" />
                <input type="hidden" name="connection_id" value={connection.id} />
                <button
                  type="submit"
                  class="workspace-action"
                  disabled={connection.discovery_status in [:pending, :running]}
                  aria-describedby={
                    connection.discovery_status && "github-discovery-status-#{connection.id}"
                  }
                >Refresh account access</button>
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
            <p :if={connection.last_error && connection.status == :ready} class="connection-warning">
              {error_label(connection.last_error)}
            </p>
          </article>
        </div>
      </div>
      <.form
        :if={
          @configured && @connected && @auth.status not in [:pending, :exchanging, :failed] &&
            !@authorization_message
        }
        for={%{}}
        id="github-sign-in-form"
        action="/connections/github"
        method="post"
        class="github-add-account"
      >
        <input type="hidden" name="operation" value="sign_in" />
        <button type="submit" class="workspace-action workspace-action-primary">Connect another account</button>
      </.form>
      <section
        :if={@organizations != []}
        class="github-installation-section"
        aria-labelledby="github-installations-heading"
      >
        <h3 id="github-installations-heading" class="github-register-title github-installations-label">
          Installation owners
        </h3>
        <div class="installation-owner-list">
          <article
            :for={org <- @organizations}
            id={"github-connection-#{org.id}"}
            class="github-installation-row"
          >
            <div class="github-org-heading">
              <div>
                <h4>{org.login}</h4>
                <p class="mail-muted">
                  {owner_label(org)} · {length(org.repositories)} repositories in snapshot · {workspace_names(
                    org.id,
                    @memberships,
                    @workspace_options
                  )}
                </p>
                <.connection_activity_links
                  :if={org.status == :ready}
                  organization={org}
                  memberships={@memberships}
                  workspace_options={@workspace_options}
                />
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
              Choose repositories on GitHub for this owner, then connect your account again to restore access.
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
            <.repository_picker
              :if={org.status == :ready && @workspace_options != []}
              organization={org}
              workspace_options={@workspace_options}
            />
          </article>
        </div>
      </section>
      <p :if={@connected && @organizations == []} class="github-state-message mail-muted">
        Your account is connected, but the app has no accessible repository accounts or organizations.
        Choose repositories on GitHub, obtain organization approval if required, then refresh account access.
      </p>
    </section>
    """
  end

  attr :configuration_status, :atom, required: true
  attr :callback_url, :string, required: true

  def setup_help(assigns) do
    ~H"""
    <details
      :if={@configuration_status not in [:unknown, :loading, :locked, :unavailable]}
      id="github-app-setup"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary>GitHub App setup guide</summary>
      <ol class="github-setup-steps">
        <li>
          Open <a
            href="https://github.com/settings/apps/new"
            target="_blank"
            rel="noopener noreferrer"
            class="workspace-action-link"
          >Register a new GitHub App<span class="sr-only"> (opens GitHub in a new tab)</span></a>,
          not an OAuth App. Choose a unique app name and set Homepage URL to this MONOLITH installation's origin.
        </li>
        <li>
          Set <strong>Callback URL</strong>
          to <code id="github-callback-url">{@callback_url}</code>.
          Leave <strong>Expire user authorization tokens</strong>
          enabled.
          Leave <strong>Request user authorization (OAuth) during installation</strong>
          off. Start the account connection from MONOLITH so the return can be matched to this browser.
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
          generate a <strong>client secret</strong>, and copy the app URL or slug from <code>https://github.com/apps/your-app-slug</code>.
        </li>
        <li>
          Save those settings in the app client settings form, then <strong>Choose repositories on GitHub</strong>.
          Choose only the repositories you want to read, at most 100 per installation.
          An organization administrator may need to approve installation and permissions.
        </li>
        <li>
          Choose <strong>Connect GitHub account</strong>, approve access on GitHub, then return here.
          Add an account, organization or selected repositories to a workspace. Each workspace keeps its own selection.
        </li>
      </ol>
    </details>
    <details
      id="github-setup-help"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary>Access, freshness &amp; disconnecting</summary>
      <p class="mail-muted">
        Only repositories selected for accessible GitHub App installations are included, grouped by owner.
        One sign-in can access several installations; each owner or repository selection can appear in several workspaces.
        MONOLITH never fetches repository contents, comments, workflow logs, artifacts, avatars or remote images.
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
        Revoke authorization or uninstall separately in GitHub. Tokens stay in the dedicated MONOLITH keychain.
      </p>
    </details>
    """
  end

  attr :organizations, :list, required: true
  attr :memberships, :list, required: true
  attr :connections, :list, required: true
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
        attached:
          for(
            org <- assigns.organizations,
            org.id in ids,
            do:
              scoped_snapshot(
                org,
                selection(org.id, assigns.memberships, assigns.workspace.id)
              )
          ),
        available: Enum.filter(assigns.organizations, &(&1.status == :ready && &1.id not in ids)),
        connected: Enum.any?(assigns.connections, &(&1.status == :ready))
      )

    ~H"""
    <section id="workspace-github" class="workspace-github" aria-labelledby="workspace-github-heading">
      <div class="github-section-heading">
        <h3 id="workspace-github-heading" class="home-eyebrow">03 / GitHub</h3>
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
            <%= cond do %>
              <% @available != [] -> %>
                Add an account or organization, or choose specific repositories below. Connections can be reused across workspaces.
              <% @connected -> %>
                Your GitHub account is connected, but no repository owners are available to add.
                Choose repository access for the app on GitHub, then refresh account access in Connections.
              <% true -> %>
                No GitHub account is connected to MONOLITH yet. Finish connecting in Connections, then return here to choose an account, organization or repositories.
            <% end %>
          </p>
          <div :if={@available == []} class="empty-state-actions">
            <.link
              id="github-workspace-connect"
              patch="/connections/github"
              class="workspace-action workspace-action-primary"
            >
              {if @connected, do: "Review GitHub repository access", else: "Finish connecting GitHub"}
            </.link>
          </div>
        </div>
      </div>
      <article :for={org <- @attached} class="connection-card" id={"workspace-github-#{org.id}"}>
        <div class="github-org-heading">
          <div>
            <h4>{org.login}</h4>
            <p class="mail-muted">{selection_label(org.id, @memberships, @workspace.id)}</p>
            <.link
              :if={org.status == :ready}
              patch={MonolithWeb.HomeNavigation.github_activity_path(@workspace.id, org.id)}
              class="workspace-action workspace-action-link"
            >View activity</.link>
          </div>
          <.form for={%{}} action="/connections/github" method="post" id={"github-detach-#{org.id}"}>
            <input type="hidden" name="operation" value="detach" />
            <input type="hidden" name="workspace_id" value={@workspace.id} />
            <input type="hidden" name="organization_id" value={org.id} />
            <button type="submit" class="workspace-action workspace-action-danger">Remove from workspace</button>
          </.form>
        </div>
        <.health organization={org} now={@now} />
        <.home_snapshot :if={org.status == :ready && !@adding} organization={org} now={@now} />
        <p
          :if={
            org.status == :ready && !@adding && observed?(org, @now) &&
              (org.truncated || org.issues_truncated || org.actions_truncated)
          }
          class="connection-warning"
        >
          Partial snapshot. Counts describe available rows, not repository totals.
        </p>
        <p
          :if={
            org.status == :ready && !@adding && observed?(org, @now) &&
              Map.get(org, :repository_selection, false)
          }
          class="connection-warning"
        >
          Snapshot subset. Shown rows are not selected-repository totals.
        </p>
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
          <label for="github-existing-organization">GitHub account or organization</label>
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
        <.repository_picker :for={org <- @available} organization={org} workspace_id={@workspace.id} />
      </details>
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
    <div class="github-related-activity">
      <section
        class="github-review-section"
        aria-labelledby={"github-issues-heading-#{@organization.id}"}
      >
        <div class="github-review-heading">
          <h2 id={"github-issues-heading-#{@organization.id}"} class="github-readout-title">
            Issues
          </h2>
          <span class="github-section-count">
            {snapshot_size(@organization, @now, :issues)} in snapshot
          </span>
        </div>
        <div :if={observed?(@organization, @now)}>
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
            {if Map.get(@organization, :repository_selection, false),
              do: "No issues match this workspace selection in the bounded owner snapshot.",
              else:
                "Issue details unavailable in this snapshot. Check Issues read-only permission and repository access."}
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
        </div>
      </section>
      <section
        class="github-review-section"
        aria-labelledby={"github-actions-heading-#{@organization.id}"}
      >
        <div class="github-review-heading">
          <h2 id={"github-actions-heading-#{@organization.id}"} class="github-readout-title">
            Recent Actions
          </h2>
          <span class="github-section-count">
            {snapshot_size(@organization, @now, :workflow_runs)} in snapshot
          </span>
        </div>
        <div :if={observed?(@organization, @now)}>
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
            {if Map.get(@organization, :repository_selection, false),
              do:
                "No recent workflow runs match this workspace selection in the bounded owner snapshot.",
              else: "No recent workflow runs found in accessible repositories."}
          </p>
          <p
            :if={@organization.workflow_runs == [] && @organization.actions_truncated}
            class="mail-muted"
          >
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
                  if run["conclusion"] in [
                       "failure",
                       "timed_out",
                       "action_required",
                       "startup_failure"
                     ],
                     do: "github-check-failed"
                }>
                  <.status_signal
                    id={"github-run-#{@organization.id}-#{run["id"]}"}
                    state={run_signal(run)}
                    label={run_label(run)}
                  />
                </span>
                <time datetime={run["updated_at"]}>Updated {date_label(run["updated_at"])}</time>
              </div>
            </li>
          </ul>
        </div>
      </section>
    </div>
    """
  end

  attr :organization, :any, required: true
  attr :now, :any, required: true

  defp health(assigns) do
    assigns = assign(assigns, :expired, expired?(assigns.organization, assigns.now))

    ~H"""
    <div class="github-health" role="status">
      <p :if={@organization.status == :disconnected}>
        <.status_signal
          id={"github-disconnected-#{@organization.id}"}
          state={:offline}
          label="Disconnected · this owner’s activity is unavailable."
        />
      </p>
      <p :if={@organization.status == :reauthorization}>
        <.status_signal
          id={"github-sign-in-required-#{@organization.id}"}
          state={:warning}
          label="Sign-in required · review this owner’s GitHub access in Connections."
        />
      </p>
      <p :if={@organization.last_error} class="connection-warning">
        <.status_signal
          id={"github-refresh-error-#{@organization.id}"}
          state={if @organization.last_error == :rate_limited, do: :waiting, else: :warning}
          label={error_label(@organization.last_error)}
        />
      </p>
      <p :if={is_nil(@organization.fetched_at)} class="mail-muted">
        <.status_signal
          id={"github-unobserved-#{@organization.id}"}
          state={:unknown}
          label="GitHub activity not yet available."
        />
      </p>
      <p :if={@expired} class="connection-warning">
        <.status_signal
          id={"github-expired-#{@organization.id}"}
          state={:warning}
          label="Cached GitHub activity expired."
        />
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
      Enum.map(ready, &home_selection(&1, assigns.memberships))
    end
  end

  defp home_selection(org, memberships) do
    selections = Enum.filter(memberships, &(&1.organization_id == org.id))

    if selections == [] || Enum.any?(selections, &(Map.get(&1, :repository_ids, []) == [])) do
      org
    else
      ids = selections |> Enum.flat_map(& &1.repository_ids) |> Enum.uniq()

      org
      |> scoped_snapshot(ids)
      |> Map.put(
        :repositories,
        Enum.filter(Map.get(org, :repositories, []), &(&1["id"] in ids))
      )
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

  defp review_signal(%{"is_draft" => true}), do: :unknown
  defp review_signal(%{"review_decision" => "APPROVED"}), do: :ready

  defp review_signal(%{"review_decision" => decision})
       when decision in ["CHANGES_REQUESTED", "REVIEW_REQUIRED"],
       do: :warning

  defp review_signal(_), do: :unknown
  defp checks_signal("SUCCESS"), do: :ready
  defp checks_signal(value) when value in ["FAILURE", "ERROR"], do: :warning
  defp checks_signal("PENDING"), do: :waiting
  defp checks_signal(_), do: :unknown
  defp run_signal(%{"status" => "completed", "conclusion" => "success"}), do: :ready

  defp run_signal(%{"status" => "completed", "conclusion" => conclusion})
       when conclusion in ["failure", "timed_out", "action_required", "startup_failure"],
       do: :warning

  defp run_signal(%{"status" => status})
       when status in ["in_progress", "queued", "requested", "waiting", "pending"],
       do: :waiting

  defp run_signal(_), do: :unknown

  defp snapshot_size(org, now, kind) do
    rows = Map.fetch!(org, kind)

    partial =
      case kind do
        :pull_requests -> org.truncated
        :issues -> org.issues_truncated
        :workflow_runs -> org.actions_truncated
      end

    if observed?(org, now) && (rows != [] || !partial), do: length(rows), else: "—"
  end

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
    do: "GitHub refresh failed. Previously observed results may be stale."

  defp discovery_label(:pending), do: "Account access refresh queued."
  defp discovery_label(:running), do: "Refreshing account access."
  defp discovery_label(:succeeded), do: "Account access refreshed."
  defp discovery_label(:failed), do: "Account access could not be refreshed."

  defp discovery_label(:superseded),
    do: "Account access refresh was superseded. Request a fresh refresh if needed."
end
