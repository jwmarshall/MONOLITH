defmodule MonolithWeb.HomeComponents do
  @moduledoc "Daily orientation with separate account readouts and real local preferences."
  use MonolithWeb, :html

  def daily_heading(assigns) do
    ~H"""
    <div class="page-register-row page-header-row">
      <p class="page-register">01 / Home</p>
      <.lock_control />
    </div>
    <header id="daily-heading" class="home-hero" phx-hook="DailyOrientation" phx-update="ignore">
      <div class="date-block">
        <time data-daily-date class="daily-date">
          <span data-daily-weekday class="date-caption"></span>
          <span data-daily-number class="day-number"></span>
          <span data-daily-month class="date-caption"></span>
        </time>
      </div>
      <div class="home-greeting">
        <h1 id="directory-heading" tabindex="-1" data-workspace-heading>A day<br />in focus.</h1>
      </div>
    </header>
    """
  end

  attr :accounts, :list, required: true
  attr :loading, :boolean, default: false
  attr :error, :boolean, default: false

  def overview(assigns) do
    ~H"""
    <section
      id="home-overview"
      class="home-overview"
      aria-labelledby="home-mail-heading"
      aria-busy={to_string(@loading)}
    >
      <div class="home-section-heading">
        <h2 id="home-mail-heading" class="section-register">01 / Email</h2>
      </div>
      <p :if={@loading} class="home-empty" role="status">
        <.status_signal id="home-loading-signal" state={:active} label="Loading accounts…" />
      </p>
      <div :if={@error} id="home-error" class="home-empty" role="alert">
        <p>Accounts couldn’t be loaded.</p><button
          type="button"
          class="workspace-action"
          phx-click="retry_workspaces"
        >Try again</button>
      </div>
      <div :if={!@loading && !@error && @accounts == []} id="home-empty" class="empty-state">
        <.icon name="hero-envelope" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h3 class="empty-state-title">No Gmail accounts connected</h3><p class="empty-state-copy">
            Connect an account to see unread counts here. Each inbox stays separate.
          </p><.link patch="/connections/gmail" class="workspace-action workspace-action-link">Connect Gmail</.link>
        </div>
      </div>
      <ul :if={!@error && !@loading && @accounts != []} id="home-accounts" class="home-accounts">
        <.account_readout
          :for={account <- @accounts}
          account={account}
          show_connection_warning={false}
        />
      </ul>
    </section>
    """
  end

  attr :account, :map, required: true
  attr :inbox_path, :string, default: nil
  attr :show_connection_warning, :boolean, default: true

  def account_readout(assigns) do
    ~H"""
    <li id={"home-account-#{@account.id}"} class="home-account">
      <.link
        id={"open-home-account-#{@account.id}"}
        patch={@inbox_path || MonolithWeb.HomeNavigation.account_path(@account.id)}
        class="home-account-open"
        aria-label={"Open inbox for #{@account.email}"}
        aria-describedby={"home-count-#{@account.id} home-health-#{@account.id}"}
      >
        <span class="home-account-identity">
          <span class="home-account-email">{@account.email}</span>
          <span class="home-account-workspaces">
            {if @account.workspaces == [],
              do: "Not in a workspace",
              else: Enum.join(@account.workspaces, " · ")}
          </span>
        </span>
        <span id={"home-count-#{@account.id}"} class="home-unread">
          <span class="home-count">
            <span class="metric-label">UNREAD</span>
            <b aria-hidden="true">{if is_integer(@account.inbox_unread_count),
              do: @account.inbox_unread_count,
              else: "—"}</b>
            <span class="sr-only">{if is_integer(@account.inbox_unread_count),
              do: "#{@account.inbox_unread_count} total unread inbox conversations",
              else: "Total unavailable for unread inbox conversations"}</span>
          </span>
          <span class="home-count home-count-recent">
            <span class="metric-label">LAST 24H</span>
            <b aria-hidden="true">{if is_integer(@account.inbox_unread_recent_count),
              do: @account.inbox_unread_recent_count,
              else: "—"}</b>
            <span class="sr-only">{if is_integer(@account.inbox_unread_recent_count),
              do: "#{@account.inbox_unread_recent_count} received in the last 24 hours",
              else: "Last 24 hours unavailable"}</span>
          </span>
        </span>
      </.link>
      <div id={"home-health-#{@account.id}"} class="home-account-health">
        <span
          :if={@show_connection_warning && health_message(@account)}
          class="connection-warning"
        >{health_message(@account)}</span>
        <.status_signal
          :if={!@account.inbox_unread_at && !health_message(@account)}
          id={"home-unknown-#{@account.id}"}
          state={:unknown}
          label="No unread count observation available"
        />
        <.link
          :if={@account.status == :reconnect || @account.last_error == :keychain}
          patch="/connections/gmail"
          class="home-recovery workspace-action workspace-action-link"
          aria-label={"Manage connection for #{@account.email}"}
        >Connections</.link>
      </div>
    </li>
    """
  end

  attr :view, :atom, required: true, values: [:index, :focus, :startup, :cache]
  attr :startup_preference, :map, default: nil
  attr :startup_error, :boolean, default: false
  attr :startup_status, :string, default: ""
  attr :cache_forms, :map, default: %{}
  attr :cache_errors, :map, default: %{}
  attr :cache_status, :map, default: %{}
  attr :cache_load_error, :boolean, default: false

  def settings(assigns) do
    assigns =
      assign(
        assigns,
        :default_minutes,
        Application.get_env(:monolith, :workspace_idle_minutes, 3)
      )

    ~H"""
    <section id="settings-panel" aria-labelledby="directory-heading">
      <nav
        :if={@view == :index}
        id="settings-overview"
        class="connections-overview"
        aria-label="Settings"
      >
        <.link
          :for={
            {view, label, scope, description} <- [
              {:focus, "Visual focus", "This browser", "Choose when inactivity reveals the scenery."},
              {:startup, "Startup scenery", "App-wide",
               "Choose whether an eligible startup can request a paid scene."},
              {:cache, "Caching and refresh", "Per integration",
               "Choose refresh timing and retention for Gmail, Calendar and GitHub."}
            ]
          }
          id={"open-setting-#{view}"}
          patch={"/settings/#{view}"}
          class="connection-provider"
        >
          <span class="connection-provider-register">{scope}</span>
          <span class="connection-provider-copy">
            <span class="connection-provider-name">{label}</span>
            <span class="mail-muted">{description}</span>
          </span>
        </.link>
      </nav>
      <nav
        :if={@view != :index}
        id="settings-subnav"
        class="connections-subnav"
        aria-label="Settings sections"
      >
        <.link
          :for={
            {view, label} <- [
              focus: "Visual focus",
              startup: "Startup scenery",
              cache: "Caching and refresh"
            ]
          }
          id={"settings-#{view}"}
          patch={"/settings/#{view}"}
          class="workspace-nav-link"
          aria-current={if @view == view, do: "page"}
        >{label}</.link>
      </nav>
      <div :if={@view != :index} class="settings-panel">
        <section :if={@view == :focus} class="settings-section" aria-labelledby="idle-heading">
          <header class="card-section-heading">
            <p class="mail-eyebrow">Visual focus</p>
            <h2 id="idle-heading">Scenery after inactivity</h2>
          </header>
          <div class="settings-section-content">
            <p>Escape or inactivity reveals the scenery. It doesn’t lock MONOLITH or stop work.</p>
            <form
              id="idle-preference"
              phx-hook="IdlePreference"
              phx-update="ignore"
              data-default-minutes={@default_minutes}
            >
              <div class="field">
                <label for="idle-minutes">Minutes without interaction</label><input
                  id="idle-minutes"
                  name="minutes"
                  type="number"
                  min="1"
                  max="60"
                  step="1"
                  value={@default_minutes}
                  required
                  aria-describedby="idle-help"
                  class="workspace-name-input"
                /><p id="idle-help" class="settings-help">
                  1–60 minutes. Default: {@default_minutes} minutes. Saved in this browser.
                </p>
              </div>
              <button type="submit" class="workspace-action workspace-action-primary">Save preference</button>
              <p data-idle-status class="settings-status" role="status"></p>
            </form>
          </div>
        </section>
        <section :if={@view == :startup} class="settings-section" aria-labelledby="startup-heading">
          <header class="card-section-heading">
            <p class="mail-eyebrow">Scene generation</p>
            <h2 id="startup-heading">Automatic startup scenery</h2>
          </header>
          <div class="settings-section-content">
            <p>Saving this choice doesn’t generate a scene. Existing authorized work is unchanged.</p>
            <p :if={@startup_error} role="alert">
              The startup preference couldn’t be read or saved. No generation was started. Try loading Settings again.
            </p>
            <.form
              :if={@startup_preference}
              for={%{}}
              id="startup-preference"
              phx-submit="settings:startup"
            >
              <input type="hidden" name="enabled" value="false" />
              <label><input
                type="checkbox"
                name="enabled"
                value="true"
                checked={@startup_preference.enabled}
              />Allow a new scene at startup</label>
              <p>
                Opt-in only. Generation can incur Google charges and uses Google’s background interaction storage. Automatic startup has a persisted 24-hour cooldown. Manual requests always need fresh cost confirmation.
              </p>
              <p :if={!@startup_preference.environment_enabled}>
                Automatic startup is blocked by the terminal configuration. Saving an opt-in won’t override that restriction.
              </p>
              <button type="submit" class="workspace-action workspace-action-primary">Save startup choice</button>
            </.form>
            <p :if={@startup_status != ""} id="startup-status" class="settings-status" role="status">
              {@startup_status}
            </p>
          </div>
        </section>
        <section
          :if={@view == :cache}
          class="settings-section settings-cache"
          aria-labelledby="cache-heading"
        >
          <header class="card-section-heading">
            <p class="mail-eyebrow">Local data</p>
            <h2 id="cache-heading">Caching and refresh</h2>
          </header>
          <div class="settings-section-content">
            <p>
              Saved for MONOLITH, across browsers and all accounts in each integration.
              Saving doesn’t fetch data. New timing applies as normal work is next evaluated.
            </p>
            <p :if={@cache_load_error} role="alert">
              Cache preferences couldn’t be read. Reload Settings to try again.
            </p>
            <div class="settings-cache-forms">
              <.cache_preference
                :for={
                  {integration, label, minimum, maximum} <- [
                    {:gmail, "Gmail", 3, 168},
                    {:calendar, "Calendar", 3, 24},
                    {:github, "GitHub", 5, 24}
                  ]
                }
                :if={Map.has_key?(@cache_forms, integration)}
                integration={integration}
                label={label}
                minimum={minimum}
                maximum={maximum}
                form={@cache_forms[integration]}
                error={Map.get(@cache_errors, integration)}
                status={Map.get(@cache_status, integration, "")}
              />
            </div>
            <div class="settings-cache-guidance">
              <p>
                Refresh targets apply only while MONOLITH is running and unlocked.
                Sleep, queue delays and provider rate limits can delay updates.
                Manual Refresh still respects provider cooldowns.
              </p>
              <p>
                Shorter retention hides older observations on the next read; normal unlocked
                cleanup removes expired cache data. Increasing retention won’t restore expired
                observations. Removal isn’t secure erasure of backups, SQLite pages or browser copies.
              </p>
              <p>
                Gmail keeps at most 120 entries / 25 MiB per account; attachments aren’t cached.
                Calendar keeps one browser-day context, not calendar history. GitHub keeps bounded
                activity snapshots. Credentials and security lifetimes aren’t changed here.
              </p>
            </div>
          </div>
        </section>
      </div>
      <section
        :if={@view == :focus}
        class="settings-accessibility"
        aria-labelledby="accessibility-heading"
      >
        <h2 id="accessibility-heading">Accessibility preferences</h2><p>
          Reduced motion and forced colors follow your browser or system setting. Mouse movement neither wakes the working plane nor extends visual focus.
        </p>
      </section>
    </section>
    """
  end

  attr :integration, :atom, required: true
  attr :label, :string, required: true
  attr :minimum, :integer, required: true
  attr :maximum, :integer, required: true
  attr :form, :any, required: true
  attr :error, :map, default: nil
  attr :status, :string, required: true

  defp cache_preference(assigns) do
    fields = if assigns.error, do: assigns.error.fields, else: []

    assigns =
      assign(assigns,
        refresh_error: :refresh_minutes in fields,
        retention_error: :retention_hours in fields
      )

    ~H"""
    <.form
      for={@form}
      id={"cache-#{@integration}"}
      phx-submit="settings:cache"
      phx-change="settings:cache-draft"
    >
      <fieldset>
        <legend>{@label}</legend>
        <input type="hidden" name="integration" value={@integration} />
        <p :if={@error} id={"cache-#{@integration}-error"} role="alert">
          <%= if @error.fields == [] do %>
            Settings couldn’t be saved. Your saved preferences haven’t changed. Try again.
          <% else %>
            Settings couldn’t be saved. Review the highlighted fields, then try again.
            <a :if={@refresh_error} href={"#cache-#{@integration}-refresh"}>Review refresh frequency</a>
            <a :if={@retention_error} href={"#cache-#{@integration}-retention"}>Review retention</a>
          <% end %>
        </p>
        <div class="field">
          <label for={"cache-#{@integration}-refresh"}>Refresh frequency (minutes)</label>
          <input
            id={"cache-#{@integration}-refresh"}
            name={@form[:refresh_minutes].name}
            value={@form[:refresh_minutes].value}
            type="number"
            min={@minimum}
            max="60"
            step="1"
            required
            class="workspace-name-input"
            aria-invalid={to_string(@refresh_error)}
            aria-describedby={"cache-#{@integration}-refresh-help#{if @refresh_error, do: " cache-#{@integration}-refresh-error"}"}
          />
          <p id={"cache-#{@integration}-refresh-help"} class="settings-help">
            {@minimum}–60 minutes. Default: {@minimum} minutes.
          </p>
          <p :if={@refresh_error} id={"cache-#{@integration}-refresh-error"} role="alert">
            Use a whole number from {@minimum} to 60 minutes.
          </p>
        </div>
        <div class="field">
          <label for={"cache-#{@integration}-retention"}>Keep cached data (hours)</label>
          <input
            id={"cache-#{@integration}-retention"}
            name={@form[:retention_hours].name}
            value={@form[:retention_hours].value}
            type="number"
            min="1"
            max={@maximum}
            step="1"
            required
            class="workspace-name-input"
            aria-invalid={to_string(@retention_error)}
            aria-describedby={"cache-#{@integration}-retention-help#{if @retention_error, do: " cache-#{@integration}-retention-error"}"}
          />
          <p id={"cache-#{@integration}-retention-help"} class="settings-help">
            1–{@maximum} hours. Default: {@maximum} hours.
          </p>
          <p :if={@retention_error} id={"cache-#{@integration}-retention-error"} role="alert">
            Use a whole number from 1 to {@maximum} hours.
          </p>
        </div>
        <button type="submit" class="workspace-action workspace-action-primary">
          Save {@label} cache settings
        </button>
        <p
          :if={@status != ""}
          id={"cache-#{@integration}-status"}
          class="settings-status"
          role="status"
        >
          {@status}
        </p>
      </fieldset>
    </.form>
    """
  end

  defp health_message(%{status: :reconnect}), do: "Reconnect required"
  defp health_message(%{last_error: :keychain}), do: "Credential store unavailable"

  defp health_message(account) do
    case account.inbox_unread_error || account.last_error do
      :rate_limited -> "Gmail rate limit · waiting to retry"
      :reconnect -> "Reconnect required"
      :keychain -> "Credential store unavailable"
      nil -> nil
      _ -> "Update failed · retrying"
    end
  end
end
