defmodule LovelaceWeb.MailComponents do
  @moduledoc "Read-only mail UI. Provider strings are always escaped plain text."
  use LovelaceWeb, :html

  alias Lovelace.Mail.ViewData

  attr :mail, :map, required: true
  attr :workspace, :map, required: true

  def panel(assigns) do
    # Local render assigns only; never copy provider content into the LV socket.
    data = ViewData.get(assigns.mail.data_ref)

    assigns =
      assigns
      |> assign(:account, Enum.find(assigns.mail.accounts, &(&1.id == assigns.mail.account_id)))
      |> assign(:threads, Enum.take(Map.get(data || %{}, "threads", []), 20))
      |> assign(:messages, Map.get(data || %{}, "messages", []))
      |> assign(:payload_expired, assigns.mail.data_loaded && is_nil(data))

    ~H"""
    <section id="mail-panel" class="mail-panel" aria-labelledby="mail-heading">
      <div class="mail-heading">
        <div>
          <p class="mail-eyebrow">Read-only Gmail</p>
          <h3 id="mail-heading" tabindex="-1">{if @account, do: @account.email, else: "Mail"}</h3>
          <p class="mail-muted">Separate accounts. Nothing sent, changed, or marked as read.</p>
        </div>
        <button
          :if={@account}
          type="button"
          class="workspace-action"
          phx-click={JS.push("mail:accounts") |> JS.focus(to: "#mail-heading")}
        >
          All accounts
        </button>
      </div>

      <p :if={@mail.notice} id="mail-notice" class="mail-notice" role="status">{@mail.notice}</p>
      <div :if={@mail.directory_error} class="mail-notice" role="alert">
        <p>Accounts could not be loaded. No mailbox changes were made.</p>
        <button type="button" class="workspace-action" phx-click="mail:reload_accounts">Try again</button>
      </div>

      <div :if={!@account && !@mail.directory_error} id="mail-accounts">
        <h4 class="mail-section-title">In this workspace</h4>
        <p :if={@mail.memberships == []} class="mail-muted">
          No accounts attached yet. Connect Google once, then reuse the account in any workspace.
        </p>
        <div
          :for={account <- @mail.accounts}
          :if={account.id in @mail.memberships}
          class="mail-account-row"
          id={"mail-account-#{account.id}"}
        >
          <div class="mail-account-identity">
            <button
              type="button"
              class="mail-account-open"
              phx-click={JS.push("mail:select") |> JS.focus(to: "#mail-heading")}
              phx-value-id={account.id}
              disabled={!!@mail.command}
            >
              {account.email}<span class="mail-muted">Open inbox →</span>
            </button>
            <p class="mail-muted">{account_status(account)}</p>
          </div>
          <div class="mail-actions">
            <.connect :if={account.status == :reconnect} workspace={@workspace} account={account} />
            <button
              type="button"
              class="workspace-action"
              phx-click="mail:detach"
              phx-value-id={account.id}
              disabled={!!@mail.command}
            >Detach here</button>
            <.disconnect account={account} busy={!!@mail.command} />
          </div>
        </div>

        <h4 class="mail-section-title">Available to attach</h4>
        <p :if={!Enum.any?(@mail.accounts, &(&1.id not in @mail.memberships))} class="mail-muted">
          No other connected accounts.
        </p>
        <div
          :for={account <- @mail.accounts}
          :if={account.id not in @mail.memberships}
          class="mail-account-row"
          id={"mail-available-#{account.id}"}
        >
          <div class="mail-account-identity">
            <p>{account.email}</p>
            <p class="mail-muted">{account_status(account)}</p>
          </div>
          <div class="mail-actions">
            <button
              :if={account.status == :ready}
              type="button"
              class="workspace-action"
              phx-click="mail:attach"
              phx-value-id={account.id}
              disabled={!!@mail.command}
            >Attach here</button>
            <.connect :if={account.status == :reconnect} workspace={@workspace} account={account} />
            <.disconnect account={account} busy={!!@mail.command} />
          </div>
        </div>
        <div class="mail-connect">
          <.connect workspace={@workspace} />
          <p class="mail-muted">
            Google grants read-only access. Detach removes only this workspace link; disconnect removes the account from every workspace.
          </p>
        </div>
      </div>

      <div :if={@account} id="mail-account-view">
        <.connect
          :if={@account.status == :reconnect || @mail.error == :reconnect}
          workspace={@workspace}
          account={@account}
        />
        <.form for={@mail.search_form} id="mail-search" class="mail-search" phx-submit="mail:search">
          <.input
            field={@mail.search_form[:query]}
            type="search"
            label="Search this entire Gmail account"
            class="mail-search-input"
            maxlength="1024"
            autocomplete="off"
          />
          <button type="submit" class="workspace-action" disabled={!!@mail.command}>Search</button>
        </.form>

        <div class="mail-toolbar">
          <div class="mail-actions">
            <button
              :if={@mail.thread_id}
              type="button"
              class="workspace-action"
              phx-click={JS.push("mail:back") |> JS.focus(to: "#mail-heading")}
            >← Back to results</button>
            <button
              :if={!@mail.thread_id && (@mail.query || @mail.page_token)}
              type="button"
              class="workspace-action"
              phx-click="mail:first"
            >First page</button>
            <span :if={!@mail.thread_id} class="mail-muted">{if @mail.query,
              do: "Account search results",
              else: "Inbox"}</span>
          </div>
          <button
            type="button"
            class="workspace-action"
            phx-click="mail:refresh"
            disabled={@mail.loading || !!@mail.command}
          >Refresh</button>
        </div>

        <div id="mail-status" class="mail-status" role="status" aria-live="polite">
          <p :if={@mail.loading}>
            Loading {if @mail.thread_id, do: "conversation", else: "messages"}…
          </p>
          <p :if={@mail.error}>{error_text(@mail.error)}</p>
          <p :if={@payload_expired}>This local view has expired. Refresh to load it again.</p>
          <p :if={@mail.stale && @mail.data_loaded}>
            Showing stale local mail. It may no longer match Gmail.
          </p>
          <p :if={@mail.fetched_at}>
            {if @mail.cached, do: "Local copy ·", else: "Fetched ·"}
            <time datetime={DateTime.to_iso8601(@mail.fetched_at)}>{Calendar.strftime(
              @mail.fetched_at,
              "%Y-%m-%d %H:%M:%S UTC"
            )}</time>
          </p>
        </div>

        <div :if={!@mail.thread_id} id="mail-threads" aria-busy={to_string(@mail.loading)}>
          <p :if={@mail.data_loaded && !@payload_expired && @threads == []} class="mail-empty">
            {if @mail.query, do: "No conversations match this search.", else: "Your inbox is empty."}
          </p>
          <button
            :for={thread <- @threads}
            id={"mail-thread-#{thread["id"]}"}
            type="button"
            class={["mail-thread", thread["unread"] == true && "mail-thread-unread"]}
            phx-click={JS.push("mail:thread") |> JS.focus(to: "#mail-heading")}
            phx-value-id={thread["id"]}
          >
            <span class="mail-thread-meta"><span>{thread["from"]}</span><span>{thread["date"]}</span></span>
            <span class="mail-thread-subject">{present(thread["subject"], "(No subject)")}</span>
            <span class="mail-thread-snippet">{thread["snippet"]}</span>
            <span :if={thread["unread"] == true} class="sr-only">Unread in Gmail</span>
          </button>
        </div>

        <div :if={@mail.thread_id} id="mail-conversation" aria-busy={to_string(@mail.loading)}>
          <p :if={@mail.data_loaded && !@payload_expired && @messages == []} class="mail-empty">
            No plain-text messages are available.
          </p>
          <article
            :for={message <- @messages}
            id={"mail-message-#{message["id"]}"}
            class="mail-message"
          >
            <h4>{present(message["subject"], "(No subject)")}</h4>
            <dl class="mail-message-meta">
              <dt>From</dt><dd>{message["from"]}</dd>
              <dt>To</dt><dd>{message["to"]}</dd>
              <dt>Date</dt><dd>{message["date"]}</dd>
            </dl>
            <p :if={message["text"] in [nil, ""]} class="mail-muted">
              No plain-text body. HTML and attachments are not displayed.
            </p>
            <pre :if={message["text"] not in [nil, ""]} class="mail-message-text">{message["text"]}</pre>
          </article>
          <p class="mail-muted">
            Plain text only. Remote images, links, and attachments are not loaded.
          </p>
        </div>

        <div :if={!@mail.thread_id && @mail.next_page_token} class="mail-pagination">
          <button
            type="button"
            class="workspace-action"
            phx-click="mail:next"
            disabled={@mail.loading}
          >Next page →</button>
        </div>
      </div>
    </section>
    """
  end

  attr :workspace, :map, required: true
  attr :account, :map, default: nil

  defp connect(assigns) do
    assigns =
      assign(
        assigns,
        :form,
        to_form(
          %{
            "workspace_id" => assigns.workspace.id,
            "expected_account_id" => if(assigns.account, do: assigns.account.id, else: "")
          },
          as: nil
        )
      )

    ~H"""
    <.form
      for={@form}
      id={"mail-connect-#{if @account, do: @account.id, else: "new"}"}
      action="/oauth/google/start"
      method="post"
      class="mail-oauth"
    >
      <.input
        field={@form[:workspace_id]}
        id={"mail-workspace-#{if @account, do: @account.id, else: "new"}"}
        type="hidden"
      />
      <.input
        :if={@account}
        field={@form[:expected_account_id]}
        id={"mail-expected-#{@account.id}"}
        type="hidden"
      />
      <button type="submit" class="workspace-action workspace-action-primary">{if @account,
        do: "Reconnect Google",
        else: "Connect Google account"}</button>
    </.form>
    """
  end

  attr :account, :map, required: true
  attr :busy, :boolean, required: true

  defp disconnect(assigns) do
    ~H"""
    <button
      type="button"
      class="workspace-action mail-disconnect"
      phx-click="mail:disconnect"
      phx-value-id={@account.id}
      disabled={@busy}
      data-confirm={"Disconnect #{@account.email} everywhere? This removes all its local cached mail, stored credentials, and connections from EVERY workspace, and attempts to revoke Google access. Your Gmail mailbox is not changed."}
    >Disconnect everywhere</button>
    """
  end

  defp present(value, fallback) when value in [nil, ""], do: fallback
  defp present(value, _), do: value

  defp account_status(%{status: :disconnected, last_error: :keychain}),
    do: "Disconnected locally. Credential removal needs retrying."

  defp account_status(%{status: :reconnect}), do: "Google access needs reconnecting."

  defp account_status(%{last_error: :rate_limited}),
    do: "Google rate limit reached. Background checks will wait."

  defp account_status(%{last_error: error}) when not is_nil(error),
    do: "Last check could not reach Gmail."

  defp account_status(%{last_success_at: %DateTime{} = time}),
    do: "Last successful check · " <> Calendar.strftime(time, "%Y-%m-%d %H:%M UTC")

  defp account_status(_), do: "Connected. Mail loads when opened."

  defp error_text(:reconnect),
    do: "Google access expired or was removed. Reconnect this account to continue."

  defp error_text(:rate_limited),
    do: "Google rate limit reached. Wait before trying Refresh again."

  defp error_text(:keychain),
    do: "Local credentials are unavailable. Unlock the system keychain and try again."

  defp error_text(:provider), do: "Gmail is temporarily unavailable. Try Refresh later."

  defp error_text(_),
    do: "Offline or Gmail unavailable. No new mail could be loaded. Try Refresh when connected."
end
