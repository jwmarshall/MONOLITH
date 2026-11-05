defmodule LovelaceWeb.HomeComponents do
  @moduledoc "Small daily-orientation readouts, independent of the workspace directory."
  use LovelaceWeb, :html

  def daily_heading(assigns) do
    ~H"""
    <header id="daily-heading" class="daily-heading" phx-hook="DailyOrientation" phx-update="ignore">
      <h2 id="directory-heading" tabindex="-1" data-workspace-heading data-daily-greeting>
        Good day
      </h2>
      <time data-daily-date class="daily-date"></time>
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
        <h3 id="home-mail-heading" class="home-eyebrow">Gmail</h3>
      </div>
      <p :if={@loading} class="home-empty" role="status">
        <.status_signal id="home-loading-signal" state={:active} label="Loading accounts…" />
      </p>
      <div :if={@error} id="home-error" class="home-empty" role="alert">
        <p>Accounts couldn’t be loaded.</p>
        <button type="button" class="workspace-action" phx-click="retry_workspaces">Try again</button>
      </div>
      <div :if={!@loading && !@error && @accounts == []} id="home-empty" class="empty-state">
        <.icon name="hero-envelope" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h4 class="empty-state-title">No Gmail accounts connected</h4>
          <p class="empty-state-copy">
            Connect an account to see unread counts here. Each inbox stays separate.
          </p>
          <.link patch="/connections/gmail" class="workspace-action workspace-action-link">
            Connect Gmail
          </.link>
        </div>
      </div>
      <ul :if={!@error && !@loading && @accounts != []} id="home-accounts" class="home-accounts">
        <.account_readout :for={account <- @accounts} account={account} />
      </ul>
    </section>
    """
  end

  attr :account, :map, required: true

  def account_readout(assigns) do
    ~H"""
    <li id={"home-account-#{@account.id}"} class="home-account">
      <.link
        id={"open-home-account-#{@account.id}"}
        patch={LovelaceWeb.HomeNavigation.account_path(@account.id)}
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
          <span class="home-unread-number">{if is_integer(@account.inbox_unread_count),
            do: @account.inbox_unread_count,
            else: "—"}</span>
          <span class="home-unread-label">
            unread<span :if={!is_integer(@account.inbox_unread_count)} class="sr-only"> total unavailable</span>
          </span>
        </span>
        <.icon name="hero-arrow-up-right" class="home-account-arrow size-4" />
      </.link>
      <div id={"home-health-#{@account.id}"} class="home-account-health">
        <.freshness account={@account} />
        <span :if={health_message(@account)} class="connection-warning">{health_message(@account)}</span>
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

  attr :account, :map, required: true

  def freshness(assigns) do
    ~H"""
    <span
      :if={@account.inbox_unread_at}
      id={"home-freshness-#{@account.id}"}
      class="home-freshness"
      phx-hook="ObservationTime"
      phx-update="ignore"
      data-observed-at={DateTime.to_iso8601(@account.inbox_unread_at)}
      data-warnings-only="true"
      data-failed={
        to_string(
          @account.status != :ready || !is_nil(@account.inbox_unread_error) ||
            !is_nil(@account.last_error)
        )
      }
    >
      {if @account.status != :ready || @account.inbox_unread_error || @account.last_error,
        do: "Stale unread count"}
    </span>
    """
  end

  def settings(assigns) do
    ~H"""
    <section id="settings-panel" class="settings-panel" aria-labelledby="directory-heading">
      <fieldset
        id="theme-picker"
        class="theme-picker"
        phx-hook="ThemePicker"
        phx-update="ignore"
        aria-describedby="theme-description theme-status"
      >
        <legend>Appearance</legend>
        <p id="theme-description" class="settings-description">
          Choose a palette for LOVELACE. This preference stays in this browser, not your account.
          Your scenery is unchanged.
        </p>
        <div class="theme-options">
          <label
            :for={
              {id, name} <- [
                {"charcoal", "Charcoal"},
                {"earth", "Earth"},
                {"sea-glass", "Sea Glass"},
                {"mist", "Mist"}
              ]
            }
            class="theme-option"
            data-theme-choice={id}
            for={"theme-#{id}"}
          >
            <span class="theme-swatch" aria-hidden="true"></span>
            <span class="theme-option-name">{name}</span>
            <input
              id={"theme-#{id}"}
              type="radio"
              name="theme"
              value={id}
              checked={id == "sea-glass"}
            />
          </label>
        </div>
        <p id="theme-status" class="theme-status" role="status" aria-live="polite" aria-atomic="true">
          Choose a theme to apply it in this browser.
        </p>
        <noscript>
          <p class="settings-description">Enable JavaScript to choose and save a theme.</p>
        </noscript>
      </fieldset>
    </section>
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
