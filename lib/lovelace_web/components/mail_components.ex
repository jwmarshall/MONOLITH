defmodule LovelaceWeb.MailComponents do
  @moduledoc "Read-only mail UI. Provider strings are always escaped plain text."
  use LovelaceWeb, :html

  alias Lovelace.Mail.ViewData
  alias LovelaceWeb.HomeNavigation

  attr :mail, :map, required: true
  attr :workspace, :map, default: nil

  def panel(assigns) do
    # Local render assigns only; never copy provider content into the LV socket.
    data = ViewData.get(assigns.mail.data_ref)

    assigns =
      assigns
      |> assign(:account, Enum.find(assigns.mail.accounts, &(&1.id == assigns.mail.account_id)))
      |> assign(:threads, Enum.take(Map.get(data || %{}, "threads", []), 20))
      |> assign(:messages, Map.get(data || %{}, "messages", []))
      |> assign(:conversation_subject, conversation_subject(data))
      |> assign(:payload_expired, assigns.mail.data_loaded && is_nil(data))

    ~H"""
    <section
      id="mail-panel"
      class="mail-panel"
      aria-labelledby="mail-heading"
      phx-hook="MailReader"
      data-mail-context={"#{@mail.list_key}:#{@account && @account.generation}"}
      data-mail-thread={@mail.thread_id || ""}
      data-mail-loaded={to_string(@mail.data_loaded && !@payload_expired)}
    >
      <div class={[
        "mail-heading",
        if(@account, do: "mail-inbox-heading", else: "mail-integration-heading")
      ]}>
        <div class="mail-account-identity">
          <p :if={@account} class="mail-eyebrow">Read-only Gmail</p>
          <h3 id="mail-heading" tabindex="-1">
            {if @account, do: @account.email, else: "Integrations"}
          </h3>
        </div>
        <.form
          :if={@account}
          for={@mail.search_form}
          id="mail-search"
          class="mail-search"
          phx-submit="mail:search"
          aria-label="Search Gmail"
        >
          <.input
            field={@mail.search_form[:query]}
            type="search"
            aria-label="Search Gmail"
            placeholder="Search"
            class="mail-search-input"
            maxlength="1024"
            autocomplete="off"
          />
          <button type="submit" class="workspace-action" disabled={!!@mail.command}>Search</button>
        </.form>
        <.link
          :if={!@account && !@mail.adding && @mail.scope != :home}
          id="add-integration"
          patch={HomeNavigation.workspace_path(@mail.workspace_id) <> "/integrations"}
          class="workspace-action workspace-action-primary"
        >
          <.icon name="hero-plus" class="size-4" /> Add integration
        </.link>
      </div>

      <p :if={@mail.notice} id="mail-notice" class="mail-notice" role="status">{@mail.notice}</p>
      <div :if={@mail.directory_error} class="mail-notice" role="alert">
        <p>Accounts couldn’t be loaded.</p>
        <button type="button" class="workspace-action" phx-click="mail:reload_accounts">Try again</button>
      </div>

      <div :if={!@account && !@mail.directory_error && @mail.scope != :home} id="mail-accounts">
        <div :if={@mail.memberships == []} class="integration-empty">
          <.icon name="hero-squares-plus" class="size-7" />
          <p>No Gmail accounts attached yet.</p>
        </div>
        <div class="integration-grid">
          <.integration_tile
            :for={account <- @mail.accounts}
            :if={account.id in @mail.memberships}
            account={account}
            workspace={@workspace}
            busy={!!@mail.command}
          />
        </div>
        <.add_panel :if={@mail.adding} mail={@mail} workspace={@workspace} />
      </div>

      <div :if={@account} id="mail-account-view">
        <.connect
          :if={@workspace && (@account.status == :reconnect || @mail.error == :reconnect)}
          workspace={@workspace}
          account={@account}
        />
        <.link
          :if={!@workspace && (@account.status == :reconnect || @mail.error == :reconnect)}
          patch="/connections/gmail"
          class="workspace-action"
        >Reconnect in Connections</.link>
        <div class="mail-toolbar">
          <div class="mail-actions">
            <.link
              :if={@mail.scope != :home}
              patch={HomeNavigation.workspace_path(@mail.workspace_id)}
              phx-click={JS.focus(to: "#mail-heading")}
              class="workspace-action"
            >All accounts</.link>
            <.link
              :if={@mail.thread_id}
              id="mail-back"
              patch={HomeNavigation.mail_path(@mail, %{thread_id: nil})}
              class="workspace-action"
            >← Back to results</.link>
            <.link
              :if={!@mail.thread_id && (@mail.query || @mail.page_token)}
              patch={HomeNavigation.mail_path(@mail, %{page_token: nil})}
              class="workspace-action"
            >First page</.link>
            <span :if={!@mail.thread_id} class="mail-muted">{if @mail.query,
              do: "Search results",
              else: "Inbox"}</span>
          </div>
          <div class="mail-tools">
            <details :if={@mail.fetched_at} id="mail-observation" class="mail-observation">
              <summary>
                <span
                  id="mail-freshness"
                  phx-hook="MailFreshness"
                  phx-update="ignore"
                  data-fetched-at={DateTime.to_iso8601(@mail.fetched_at)}
                  data-stale={to_string(@mail.stale || not is_nil(@mail.error))}
                  data-cached={to_string(@mail.cached)}
                >
                  {if @mail.cached, do: "Local copy ·", else: "Fetched ·"}
                  {Calendar.strftime(@mail.fetched_at, "%Y-%m-%d %H:%M:%S UTC")}
                </span>
              </summary>
              <p>
                Fetched ·
                <time datetime={DateTime.to_iso8601(@mail.fetched_at)}>{Calendar.strftime(
                  @mail.fetched_at,
                  "%Y-%m-%d %H:%M:%S UTC"
                )}</time>
              </p>
            </details>
            <button
              id="mail-refresh"
              type="button"
              class="workspace-action"
              phx-click="mail:refresh"
              disabled={@mail.loading || !!@mail.command}
            >Refresh</button>
          </div>
        </div>

        <div id="mail-status" class="mail-status" role="status" aria-live="polite" aria-atomic="true">
          <p :if={@mail.loading} id="mail-loading" class="mail-loading">
            <.status_signal
              id="mail-loading-signal"
              state={:active}
              label={"Loading #{if @mail.thread_id, do: "conversation", else: "messages"}…"}
            />
          </p>
          <p :if={@mail.error} class="mail-warning">{error_text(@mail.error)}</p>
          <p :if={@payload_expired} class="mail-warning">
            This local view has expired. Refresh to load it again.
          </p>
          <p :if={@mail.stale && @mail.data_loaded} class="mail-warning">
            Showing stale local mail. It may no longer match Gmail.
          </p>
        </div>

        <div :if={!@mail.thread_id} id="mail-threads" aria-busy={to_string(@mail.loading)}>
          <p :if={@mail.data_loaded && !@payload_expired && @threads == []} class="mail-empty">
            {if @mail.query, do: "No conversations match this search.", else: "Your inbox is empty."}
          </p>
          <.link
            :for={thread <- @threads}
            id={"mail-thread-#{thread["id"]}"}
            patch={HomeNavigation.mail_path(@mail, %{thread_id: thread["id"]})}
            class={["mail-thread", thread["unread"] == true && "mail-thread-unread"]}
            data-mail-open-thread
          >
            <span class="mail-thread-marker" aria-hidden="true"></span>
            <span class="mail-thread-content">
              <span class="mail-thread-meta">
                <span class="mail-thread-sender">{present(thread["from"], "(Unknown sender)")}</span>
                <.mail_date id={"thread-date-#{thread["id"]}"} value={thread["date"]} />
              </span>
              <span class="mail-thread-subject">{present(thread["subject"], "(No subject)")}</span>
              <span class="mail-thread-snippet">{thread["snippet"]}</span>
            </span>
            <span :if={thread["unread"] == true} class="sr-only">Unread in Gmail</span>
          </.link>
        </div>

        <section
          :if={@mail.thread_id}
          id="mail-conversation"
          class="mail-reader"
          aria-label="Conversation"
          aria-busy={to_string(@mail.loading)}
        >
          <header :if={@messages != []} class="mail-conversation-header">
            <h4 id="mail-conversation-heading" tabindex="-1">{@conversation_subject}</h4>
            <p class="mail-muted">
              {length(@messages)} {if length(@messages) == 1,
                do: "message",
                else: "messages"}
            </p>
          </header>
          <p :if={@mail.data_loaded && !@payload_expired && @messages == []} class="mail-empty">
            No plain-text messages are available.
          </p>
          <details
            :for={{message, index} <- Enum.with_index(@messages)}
            id={"mail-message-#{message["id"]}"}
            class="mail-message"
            open={index == length(@messages) - 1}
            data-mail-latest={to_string(index == length(@messages) - 1)}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary class="mail-message-summary">
              <span class="mail-message-chevron" aria-hidden="true">›</span>
              <span class="mail-message-sender">{present(message["from"], "(Unknown sender)")}</span>
              <.mail_date id={"message-date-#{message["id"]}"} value={message["date"]} />
            </summary>
            <div class="mail-message-content">
              <p
                :if={present(message["subject"], "(No subject)") != @conversation_subject}
                class="mail-message-subject"
              >
                {present(message["subject"], "(No subject)")}
              </p>
              <details
                id={"mail-message-details-#{message["id"]}"}
                class="mail-message-details"
                phx-mounted={JS.ignore_attributes("open")}
              >
                <summary>Show details<span class="sr-only"> for message {index + 1}</span></summary>
                <dl class="mail-message-meta">
                  <dt>From</dt><dd>{message["from"]}</dd>
                  <dt>To</dt><dd>{message["to"]}</dd>
                  <dt>Date</dt><dd>{message["date"]}</dd>
                </dl>
              </details>
              <p :if={message["text"] in [nil, ""]} class="mail-muted">
                No plain-text body. HTML email content is not displayed.
              </p>
              <pre :if={message["text"] not in [nil, ""]} class="mail-message-text">{message["text"]}</pre>
              <section
                :if={message["attachments"] not in [nil, []]}
                class="mail-attachments"
                aria-label={"Attachments for message #{index + 1}"}
              >
                <h5>Attachments</h5>
                <ul>
                  <li :for={attachment <- message["attachments"]} class="mail-attachment">
                    <div class="mail-attachment-meta">
                      <span class="mail-attachment-name">{attachment["filename"]}</span>
                      <span class="mail-muted">
                        {attachment["mime_type"]} · {attachment_size(attachment["size"])}
                      </span>
                    </div>
                    <a
                      :if={downloadable_attachment?(attachment["size"])}
                      class="workspace-action"
                      href={
                        attachment_path(
                          @mail.account_id,
                          @mail.thread_id,
                          message["id"],
                          attachment["attachment_id"],
                          download: true
                        )
                      }
                    >Download</a>
                    <span
                      :if={!downloadable_attachment?(attachment["size"])}
                      class="mail-muted"
                    >Larger than the 5 MiB limit</span>
                    <img
                      :if={
                        previewable_image?(attachment["mime_type"]) &&
                          downloadable_attachment?(attachment["size"])
                      }
                      src={
                        attachment_path(
                          @mail.account_id,
                          @mail.thread_id,
                          message["id"],
                          attachment["attachment_id"]
                        )
                      }
                      alt={attachment["filename"]}
                      loading="lazy"
                      referrerpolicy="no-referrer"
                    />
                  </li>
                </ul>
              </section>
            </div>
          </details>
        </section>

        <div :if={!@mail.thread_id && @mail.next_page_token} class="mail-pagination">
          <.link
            patch={HomeNavigation.mail_path(@mail, %{page_token: @mail.next_page_token})}
            class="workspace-action"
          >Next page →</.link>
        </div>
      </div>
    </section>
    """
  end

  attr :account, :map, required: true
  attr :workspace, :map, required: true
  attr :busy, :boolean, required: true

  defp integration_tile(assigns) do
    ~H"""
    <article id={"mail-account-#{@account.id}"} class="integration-tile">
      <.link
        patch={HomeNavigation.workspace_path(@workspace.id) <> "/accounts/" <> @account.id <> "/mail"}
        class="mail-account-open integration-tile-open"
        phx-click={JS.focus(to: "#mail-heading")}
        aria-label={"Open inbox for #{@account.email}"}
        aria-describedby={"integration-status-#{@account.id}"}
      >
        <.icon name="hero-envelope" class="integration-icon size-6" />
        <span class="mail-eyebrow">Gmail · Read-only</span>
        <span class="integration-name">{@account.email}</span>
        <span
          id={"integration-status-#{@account.id}"}
          class={["mail-muted", needs_attention?(@account) && "connection-warning"]}
        >
          <.account_signal account={@account} id={"integration-signal-#{@account.id}"} embedded />
        </span>
        <.icon name="hero-arrow-up-right" class="workspace-card-arrow size-5" />
      </.link>
      <details id={"integration-menu-#{@account.id}"} class="workspace-menu">
        <summary aria-label={"Manage #{@account.email}"} title={"Manage #{@account.email}"}>
          <.icon name="hero-ellipsis-horizontal" class="size-5" />
        </summary>
        <div class="workspace-menu-actions">
          <button
            id={"detach-#{@account.id}"}
            type="button"
            class="workspace-action"
            phx-click={
              JS.remove_attribute("open", to: "#integration-menu-#{@account.id}")
              |> JS.push("mail:detach")
              |> JS.focus(to: "#mail-heading")
            }
            phx-value-id={@account.id}
            disabled={@busy}
          >Remove from workspace</button>
        </div>
      </details>
      <div :if={@account.status == :reconnect} class="integration-recovery">
        <.connect workspace={@workspace} account={@account} busy={@busy} />
      </div>
    </article>
    """
  end

  attr :mail, :map, required: true
  attr :workspace, :map, required: true

  defp add_panel(assigns) do
    ~H"""
    <section
      id="integration-add-panel"
      class="integration-add-panel"
      aria-labelledby="integration-add-heading"
    >
      <div class="mail-heading">
        <div>
          <h4 id="integration-add-heading" tabindex="-1" phx-mounted={JS.focus()}>Add integration</h4>
          <p class="mail-muted">
            Add an existing account or connect Google.
          </p>
        </div>
        <.link
          id="close-add-integration"
          patch={HomeNavigation.workspace_path(@workspace.id)}
          phx-click={JS.focus(to: "#mail-heading")}
          class="workspace-action"
        >
          Done
        </.link>
      </div>
      <h5 class="mail-section-title">Available connections</h5>
      <p :if={!Enum.any?(@mail.accounts, &(&1.id not in @mail.memberships))} class="mail-muted">
        No other connected accounts.
      </p>
      <div
        :for={account <- @mail.accounts}
        :if={account.id not in @mail.memberships}
        id={"mail-available-#{account.id}"}
        class="connection-row"
      >
        <div class="mail-account-identity">
          <p>{account.email}</p>
          <p class="mail-muted">
            <.account_signal account={account} id={"available-signal-#{account.id}"} />
          </p>
        </div>
        <button
          :if={account.status == :ready}
          id={"attach-#{account.id}"}
          type="button"
          class="workspace-action"
          phx-click={JS.push("mail:attach") |> JS.focus(to: "#mail-heading")}
          phx-value-id={account.id}
          disabled={!!@mail.command}
        >
          <.icon name="hero-plus" class="size-4" /> Add to workspace
        </button>
        <.connect
          :if={account.status == :reconnect}
          workspace={@workspace}
          account={account}
          busy={!!@mail.command}
        />
        <p :if={account.status == :disconnected} class="mail-muted">
          Retry credential removal in Connections.
        </p>
      </div>
      <div class="mail-connect">
        <.connect workspace={@workspace} busy={!!@mail.command} />
        <p class="mail-muted">
          Read-only Gmail. Reusable across workspaces.
        </p>
      </div>
    </section>
    """
  end

  attr :mail, :map, required: true
  attr :workspace_options, :list, required: true

  def connections(assigns) do
    ~H"""
    <section
      id="connections-panel"
      class="connections-panel"
      aria-labelledby="gmail-connections-heading"
    >
      <div class="connections-heading">
        <h3 id="gmail-connections-heading" class="mail-section-title">Gmail accounts</h3>
        <button
          id="new-gmail-connection"
          type="button"
          class="workspace-action workspace-action-primary"
          phx-click="mail:new_connection"
          disabled={!!@mail.command || @mail.directory_error}
        >
          <.icon name="hero-plus" class="size-4" /> Add Gmail account
        </button>
      </div>
      <p class="mail-muted">
        Read-only · Separate inboxes
      </p>
      <p :if={@mail.notice} id="mail-notice" class="mail-notice" role="status">{@mail.notice}</p>
      <div :if={@mail.directory_error} class="mail-notice" role="alert">
        <p>Connections couldn’t be loaded.</p>
        <button type="button" class="workspace-action" phx-click="mail:reload_accounts">Try again</button>
      </div>
      <p :if={!@mail.directory_error && @mail.accounts == []} class="integration-empty">
        No Gmail accounts connected yet.
      </p>
      <div class="gmail-connection-list">
        <article
          :for={account <- @mail.accounts}
          id={"connection-account-#{account.id}"}
          class="connection-card gmail-connection-card"
          aria-labelledby={"connection-email-#{account.id}"}
        >
          <div class="connection-identity">
            <.icon name="hero-envelope" class="integration-icon size-5" />
            <div class="mail-account-identity">
              <h4 id={"connection-email-#{account.id}"}>{account.email}</h4>
              <p class={["mail-muted", needs_attention?(account) && "connection-warning"]}>
                <.account_signal account={account} id={"connection-signal-#{account.id}"} />
              </p>
            </div>
          </div>
          <div class="mail-actions">
            <button
              :if={account.status != :disconnected}
              id={"check-credentials-#{account.id}"}
              type="button"
              class="workspace-action"
              phx-click="mail:check_credentials"
              phx-value-id={account.id}
              aria-label={"Check Keychain access for #{account.email}"}
              disabled={!!@mail.command || !!@mail.credential_check}
            >Check Keychain</button>
            <.connect
              :if={account.status == :reconnect}
              account={account}
              workspace_options={@workspace_options}
              busy={!!@mail.command || !!@mail.credential_check}
            />
            <.disconnect account={account} busy={!!@mail.command || !!@mail.credential_check} />
          </div>
          <.credential_check account={account} check={credential_check_result(@mail, account)} />
        </article>
      </div>
      <LovelaceWeb.ModalComponents.modal
        :if={@mail.connecting}
        id="gmail-connection-modal"
        title="Add Gmail account"
        on_cancel="mail:close_connection"
        return_focus="#new-gmail-connection"
        initial_focus="#mail-workspace-new"
      >
        <p id="gmail-connection-hint" class="mail-muted">
          Choose a workspace for this read-only account. Reuse it elsewhere anytime.
        </p>
        <.connect workspace_options={@workspace_options} busy={!!@mail.command} />
        <button
          type="button"
          class="workspace-action gmail-connection-cancel"
          phx-click="mail:close_connection"
        >Cancel</button>
      </LovelaceWeb.ModalComponents.modal>
      <details
        id="gmail-keychain-help"
        class="mail-muted connection-help"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>About Keychain access</summary>
        <p>
          Check Keychain reads only this account’s local credential. It does not contact Google,
          change permissions, or refresh mail. A readable credential does not verify Google access.
        </p>
        <p>
          An unlocked login keychain can still deny an individual item. In macOS Keychain Access,
          review the LOVELACE Gmail item’s access for the current lovelace-keychain helper.
          A rebuilt helper can have a different security identity even when the displayed name is unchanged.
        </p>
        <p>
          Do not delete credentials or allow all applications. Rebuilding again is not an access
          repair. Reconnect Google only for a missing credential or expired Google authorization.
        </p>
      </details>
      <details
        id="gmail-disconnect-help"
        class="mail-muted connection-help"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Removal &amp; disconnecting</summary>
        <p>
          Remove from workspace only detaches that link. Disconnect everywhere removes all workspace links,
          cached mail and credentials, and attempts Google revocation. Your Gmail mailbox is unchanged.
        </p>
      </details>
    </section>
    """
  end

  attr :account, :map, required: true
  attr :check, :map, default: nil

  defp credential_check(assigns) do
    ~H"""
    <div
      :if={@check}
      id={"credential-check-#{@account.id}"}
      class="credential-check mail-muted"
      role="status"
      aria-live="polite"
      aria-atomic="true"
    >
      <p class={@check.status not in [:accessible, :checking] && "connection-warning"}>
        <.status_signal
          id={"credential-check-signal-#{@account.id}"}
          state={credential_signal_state(@check.status)}
          label={credential_check_text(@check.status)}
          text={@check.status != :checking}
        />
      </p>
      <p :if={@check.status == :locked}>
        An unlocked keychain can still deny this item. Review helper access in Keychain Access;
        see About Keychain access below. No permissions were changed.
      </p>
      <p :if={@check.status == :timeout}>
        The local helper did not respond in time. This does not establish a Google failure.
      </p>
      <p :if={@check.status == :unavailable}>
        The helper could not complete the read. Credential presence and access are unknown.
      </p>
      <p :if={@check.status == :not_found}>
        No stored credential was found for this account. Reconnect Google to restore access.
      </p>
      <p :if={@check[:checked_at]}>
        Local check ·
        <time datetime={DateTime.to_iso8601(@check.checked_at)}>{Calendar.strftime(
          @check.checked_at,
          "%Y-%m-%d %H:%M:%S UTC"
        )}</time>
        · Mail sync status is unchanged.
      </p>
    </div>
    """
  end

  defp credential_check_result(mail, account) do
    case mail.credential_check do
      {id, generation, _} when id == account.id and generation == account.generation ->
        %{status: :checking}

      _ ->
        Map.get(mail.credential_checks, account.id)
    end
  end

  defp credential_signal_state(:checking), do: :active
  defp credential_signal_state(:accessible), do: :ready
  defp credential_signal_state(_), do: :warning

  defp credential_check_text(:checking), do: "Checking local Keychain access…"
  defp credential_check_text(:accessible), do: "Credential readable · Google access not checked."

  defp credential_check_text(:locked),
    do: "Keychain access denied or interaction required (locked)."

  defp credential_check_text(:not_found), do: "Credential not found (not_found)."
  defp credential_check_text(:timeout), do: "Keychain helper timed out (timeout)."

  defp credential_check_text(:invalid_account),
    do: "Invalid local account identifier (invalid_account)."

  defp credential_check_text(:invalid_value),
    do: "Invalid stored credential format (invalid_value)."

  defp credential_check_text(:changed), do: "Connection changed. Check again."
  defp credential_check_text(_), do: "Keychain unavailable (unavailable)."

  attr :workspace, :map, default: nil
  attr :workspace_options, :list, default: []
  attr :account, :map, default: nil
  attr :busy, :boolean, default: false

  defp connect(assigns) do
    assigns =
      assign(
        assigns,
        :form,
        to_form(
          %{
            "workspace_id" => if(assigns.workspace, do: assigns.workspace.id, else: ""),
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
        :if={@workspace}
        field={@form[:workspace_id]}
        id={"mail-workspace-#{if @account, do: @account.id, else: "new"}"}
        type="hidden"
      />
      <.input
        :if={!@workspace}
        field={@form[:workspace_id]}
        id={"mail-workspace-#{if @account, do: @account.id, else: "new"}"}
        type="select"
        label={if @account, do: "Reconnect and add to", else: "Connect and add to"}
        options={@workspace_options}
        prompt="Choose workspace"
        class="connection-workspace-select"
        required
        disabled={@busy}
      />
      <.input
        :if={@account}
        field={@form[:expected_account_id]}
        id={"mail-expected-#{@account.id}"}
        type="hidden"
      />
      <button type="submit" class="workspace-action workspace-action-primary" disabled={@busy}>{if @account,
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

  attr :id, :string, required: true
  attr :value, :string, default: nil

  defp mail_date(assigns) do
    ~H"""
    <time id={@id} phx-hook="MailDate" phx-update="ignore" data-mail-date={@value} title={@value}>
      {present(@value, "Date unavailable")}
    </time>
    """
  end

  defp conversation_subject(data) do
    case Map.get(data || %{}, "messages", []) do
      [message | _] -> present(message["subject"], "(No subject)")
      _ -> "(No subject)"
    end
  end

  attr :id, :string, required: true
  attr :account, :map, required: true
  attr :embedded, :boolean, default: false

  defp account_signal(assigns) do
    ~H"""
    <.status_signal
      id={@id}
      state={account_signal_state(@account)}
      label={account_status(@account)}
      text={needs_attention?(@account)}
      embedded={@embedded}
    />
    """
  end

  defp account_signal_state(%{status: :disconnected}), do: :offline
  defp account_signal_state(%{status: :reconnect}), do: :warning
  defp account_signal_state(%{last_error: error}) when not is_nil(error), do: :warning
  defp account_signal_state(%{last_success_at: %DateTime{}}), do: :ready
  defp account_signal_state(_), do: :unknown

  defp needs_attention?(account), do: account.status != :ready || not is_nil(account.last_error)

  defp present(value, fallback) when value in [nil, ""], do: fallback
  defp present(value, _), do: value

  defp previewable_image?(type),
    do: type in ["image/jpeg", "image/png", "image/gif", "image/webp"]

  defp attachment_size(size) when is_integer(size) and size >= 0 do
    if size < 1024, do: "#{size} B", else: "#{Float.round(size / 1024, 1)} KB"
  end

  defp attachment_size(_), do: "Size unavailable"

  defp downloadable_attachment?(size),
    do: is_integer(size) and size >= 0 and (size == 0 or size <= 5 * 1024 * 1024)

  defp attachment_path(account, thread, message, attachment, opts \\ []) do
    path =
      "/accounts/#{account}/mail/threads/#{thread}/messages/#{message}/attachments/#{attachment}"

    if Keyword.get(opts, :download, false), do: path <> "?download=1", else: path
  end

  defp account_status(%{status: :disconnected, last_error: :keychain}),
    do: "Disconnected locally. Credential removal needs retrying."

  defp account_status(%{status: :disconnected}), do: "Disconnected locally."

  defp account_status(%{status: :reconnect}), do: "Google access needs reconnecting."

  defp account_status(%{last_error: :keychain}),
    do: "Local Keychain access unavailable. Check credentials in Connections."

  defp account_status(%{last_error: :rate_limited}),
    do: "Google rate limit reached. Background checks will wait."

  defp account_status(%{last_error: error}) when not is_nil(error),
    do: "Last check could not reach Gmail."

  defp account_status(%{last_success_at: %DateTime{} = time}),
    do: "Last successful check · " <> Calendar.strftime(time, "%Y-%m-%d %H:%M UTC")

  defp account_status(_), do: "Connected · no successful Gmail check yet. Mail loads when opened."

  defp error_text(:reconnect),
    do: "Google access expired or was removed. Reconnect this account to continue."

  defp error_text(:rate_limited),
    do: "Google rate limit reached. Wait before trying Refresh again."

  defp error_text(:keychain),
    do:
      "Local credentials are unavailable. Check Keychain access in Connections; an unlocked keychain can still deny access."

  defp error_text(:provider), do: "Gmail is temporarily unavailable. Try Refresh later."

  defp error_text(_),
    do: "Offline or Gmail unavailable. No new mail could be loaded. Try Refresh when connected."
end
