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
      <p :if={@loading} class="home-empty" role="status">Loading accounts…</p>
      <div :if={@error} id="home-error" class="home-empty" role="alert">
        <p>Accounts couldn’t be loaded.</p>
        <button type="button" class="workspace-action" phx-click="retry_workspaces">Try again</button>
      </div>
      <div :if={!@loading && !@error && @accounts == []} id="home-empty" class="home-empty">
        <p>No Gmail accounts connected.</p>
        <button type="button" class="workspace-action" phx-click="show_connections">Connect Gmail</button>
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
      <button
        id={"open-home-account-#{@account.id}"}
        type="button"
        class="home-account-open"
        phx-click="open_home_account"
        phx-value-id={@account.id}
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
      </button>
      <div id={"home-health-#{@account.id}"} class="home-account-health">
        <.freshness account={@account} />
        <span :if={health_message(@account)} class="connection-warning">{health_message(@account)}</span>
        <button
          :if={@account.status == :reconnect || @account.last_error == :keychain}
          type="button"
          class="home-recovery"
          phx-click="show_connections"
          aria-label={"Manage connection for #{@account.email}"}
        >Connections →</button>
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
