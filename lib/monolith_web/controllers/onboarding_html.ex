defmodule MonolithWeb.OnboardingHTML do
  use MonolithWeb, :html

  alias Monolith.Onboarding

  def show(assigns) do
    assigns = Map.put(assigns, :calendar_account, calendar_account(assigns.connection))

    ~H"""
    <Layouts.stage
      id="onboarding-stage"
      class="stage-static"
      background={@background}
      data-first-run-entrance={if @first_run_entrance?, do: "true", else: "false"}
      static
    >
      <a class="workspace-skip-link" href="#main-content">Skip to setup</a>
      <main
        id="main-content"
        class="workspace-glass owner-glass onboarding-glass"
        aria-labelledby="onboarding-heading"
      >
        <section class="onboarding-content">
          <header>
            <p class="onboarding-eyebrow">LOVELACE · Setup</p>
            <h1 id="onboarding-heading" tabindex="-1">{title(@step)}</h1>
            <p>
              Your place is saved locally when you continue. Google, Gmail, and Calendar are optional; you control every Google change.
            </p>
          </header>
          <nav aria-label="Setup steps" class="onboarding-steps">
            <ol>
              <li :for={{step, number} <- Enum.with_index(Onboarding.steps(), 1)}>
                <a href={Onboarding.path(step)} aria-current={if step == @step, do: "step"}>
                  <span aria-hidden="true">{number}.</span> {short_title(step)}
                </a>
              </li>
            </ol>
          </nav>
          <p
            :if={@error && @error != :calendars_saved}
            id="onboarding-error"
            class="onboarding-error"
            role="alert"
          >
            {error_message(@error)}
          </p>
          <div class="onboarding-instructions">
            <%= case @step do %>
              <% :workspace -> %>
                <p>
                  Workspaces are areas of your life. Name your first one—for example, Work, Home, or Study.
                  Integrations are optional. You can use your workspace now and add connections later.
                </p>
                <form
                  id="onboarding-workspace"
                  action="/onboarding/workspace"
                  method="post"
                  class="onboarding-form"
                >
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <input type="hidden" name="operation" value="save_workspace" />
                  <label for="onboarding-workspace-name">Workspace name</label>
                  <input
                    id="onboarding-workspace-name"
                    name="name"
                    type="text"
                    value={@workspace_name}
                    autocomplete="off"
                    required
                    maxlength="64"
                    aria-describedby="onboarding-workspace-hint"
                  />
                  <p id="onboarding-workspace-hint">
                    Up to 64 characters. You can rename this workspace later.
                    Returning to this step updates the same workspace; it does not create another.
                  </p>
                  <button class="workspace-action workspace-action-primary" type="submit">
                    Continue
                  </button>
                </form>
              <% :project -> %>
                <p>
                  Optionally use your own Google Cloud project for a private, read-only Gmail connection. You can set up Google later in Connections. LOVELACE will not create or change a Google project for you.
                </p>
                <ol>
                  <li>
                    <.external href="https://console.cloud.google.com/">
                      Open Google Cloud Console
                    </.external>
                    and select the project picker at the top.
                  </li>
                  <li>
                    Choose <strong>New Project</strong>, give it a recognizable name such as LOVELACE, and create it. Select that project before continuing.
                  </li>
                  <li>
                    <.external href="https://console.cloud.google.com/apis/library/gmail.googleapis.com">
                      Open Gmail API
                    </.external>
                    in the API Library and choose <strong>Enable</strong>. If it is already enabled, leave it enabled.
                  </li>
                </ol>
                <p>
                  For optional Calendar agendas, also
                  <.external href="https://console.cloud.google.com/apis/library/calendar-json.googleapis.com">
                    open Google Calendar API
                  </.external>
                  and enable it in the same project. No billing is needed for this guide.
                </p>
                <.actions
                  step={@step}
                  csrf_token={@csrf_token}
                  skip="Skip Google"
                />
              <% :authentication -> %>
                <p>
                  In the same project, configure <strong>Google Auth Platform</strong>. These settings describe your own consent application, not a new LOVELACE owner identity.
                </p>
                <ol>
                  <li>
                    <.external href="https://console.cloud.google.com/auth/overview">Open Google Auth Platform</.external>. If prompted, choose <strong>Get started</strong>.
                  </li>
                  <li>
                    Under <strong>Branding</strong>, enter an app name such as LOVELACE, your user support email, and your developer contact email. Complete Google's required fields and save.
                  </li>
                  <li>
                    Choose <strong>External</strong>
                    for personal Gmail or Google accounts from different organizations.
                    <strong>Internal</strong>
                    works only for the project's own Google Workspace organization.
                  </li>
                  <li>
                    Under <.external href="https://console.cloud.google.com/auth/scopes">Data Access</.external>, choose
                    <strong>Add or remove scopes</strong>
                    and add the Gmail scopes below. If you want Calendar agendas, add the two Calendar scopes too, then save.
                  </li>
                </ol>
                <ul class="onboarding-scopes" aria-label="Required Gmail scopes">
                  <li><code>openid</code></li>
                  <li><code>https://www.googleapis.com/auth/userinfo.email</code></li>
                  <li><code>https://www.googleapis.com/auth/gmail.readonly</code></li>
                </ul>
                <h2>Optional Google Calendar scopes</h2>
                <ul class="onboarding-scopes" aria-label="Optional Google Calendar scopes">
                  <li><code>https://www.googleapis.com/auth/calendar.events.readonly</code></li>
                  <li><code>https://www.googleapis.com/auth/calendar.calendarlist.readonly</code></li>
                </ul>
                <p>
                  These let LOVELACE read events and list your calendars, including shared calendars.
                  Adding them to your Google project's consent configuration does not grant LOVELACE access.
                  The Gmail connection step requests Gmail-only access; the optional Calendar step then lets you authorize Calendar for the same account.
                </p>
                <p>
                  The console uses <code>userinfo.email</code>; OAuth may show its equivalent
                  <code>email</code>
                  alias. Do not add <code>userinfo.profile</code>, write scopes, service accounts, or domain-wide delegation.
                </p>
                <.actions
                  step={@step}
                  csrf_token={@csrf_token}
                  skip="Skip Google"
                />
              <% :audience -> %>
                <p>
                  <.external href="https://console.cloud.google.com/auth/audience">
                    Open Audience
                  </.external>
                  in Google Auth Platform and review the publishing status for the selected project.
                </p>
                <h2>If you use Testing</h2>
                <p>
                  Add every Google account you intend to connect under <strong>Test users</strong>. With External apps in <strong>Testing</strong>, Gmail refresh tokens generally expire after <strong>seven days</strong>. Reconnecting every week is not a durable setup.
                </p>
                <h2>For ongoing personal use</h2>
                <p>
                  Review <.external href="https://support.google.com/cloud/answer/13464323">Google's personal-use verification exemption</.external>. If your app qualifies, use
                  <strong>Publish app</strong>
                  to move its publishing status to <strong>In production</strong>, then connect or reconnect Gmail. Do not assume an old Testing grant becomes permanent.
                </p>
                <p>
                  <code>gmail.readonly</code>
                  is a restricted scope. Personal-use exemptions do not remove Google's data-use rules, unverified-app warnings, user caps, or Workspace administrator restrictions. Managed accounts may require administrator approval. Tokens can also expire or be revoked for other reasons.
                </p>
                <p class="onboarding-note">
                  Continue records your place in this guide. It does not verify your audience, publication, scopes, or exemption with Google.
                </p>
                <.actions
                  step={@step}
                  csrf_token={@csrf_token}
                  skip="Skip Google"
                />
              <% :client -> %>
                <ol>
                  <li>
                    <.external href="https://console.cloud.google.com/auth/clients">
                      Open Clients
                    </.external>
                    in Google Auth Platform, then choose <strong>Create client</strong>.
                  </li>
                  <li>
                    For <strong>Application type</strong>, select <strong>Desktop app</strong>. Name it, create it, and copy its client ID and client secret into the private form below.
                  </li>
                </ol>
                <p>
                  A Desktop client supports LOVELACE's local loopback callback without registering each port. Do not choose Web application, a service account, or the obsolete out-of-band flow for this guide.
                </p>
                <p>
                  A Desktop client's secret is not a security boundary for a distributed app. Still keep both values local: never put them in chat, source, shell history, or a URL, and do not commit downloaded client JSON.
                </p>
                <form
                  id="google-setup-credentials"
                  action="/onboarding/credentials"
                  method="post"
                  autocomplete="off"
                  class="onboarding-form"
                >
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <label for="google-client-id">Client ID</label>
                  <input
                    id="google-client-id"
                    name="client_id"
                    type="password"
                    autocomplete="off"
                    spellcheck="false"
                    autocapitalize="none"
                    required
                    maxlength="8192"
                    aria-describedby="google-client-privacy"
                  />
                  <label for="google-client-secret">Client secret</label>
                  <input
                    id="google-client-secret"
                    name="client_secret"
                    type="password"
                    autocomplete="off"
                    spellcheck="false"
                    autocapitalize="none"
                    required
                    maxlength="8192"
                    aria-describedby="google-client-privacy"
                  />
                  <p id="google-client-privacy">
                    Saved directly to your unlocked, dedicated LOVELACE keychain. Values are never shown again here. Saving does not contact Google, verify this client, or require a restart.
                  </p>
                </form>
                <.actions
                  step={@step}
                  csrf_token={@csrf_token}
                  submit_form="google-setup-credentials"
                  saved_client={@progress && @progress.credentials_saved}
                  skip="Skip Google"
                />
              <% :connect -> %>
                <p>
                  Optionally connect the intended Google account to your workspace. Google authorization starts only when you press the button below.
                </p>
                <.connection_status connection={@connection} />
                <form
                  :if={@workspace && @progress && @progress.credentials_saved}
                  id="onboarding-google-connect"
                  action="/oauth/google/start"
                  method="post"
                  class="onboarding-form"
                >
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <input type="hidden" name="workspace_id" value={@workspace.id} />
                  <input type="hidden" name="capability" value="gmail" />
                  <input type="hidden" name="origin" value="onboarding" />
                  <p>
                    <strong>Destination:</strong> {@workspace.name}
                  </p>
                  <p>
                    <strong>Access:</strong>
                    read-only Gmail plus your Google identity and email address. LOVELACE cannot send, archive, delete, or mark messages as read.
                  </p>
                  <button class="workspace-action workspace-action-primary" type="submit">Connect Google account</button>
                </form>
                <p :if={!@progress || !@progress.credentials_saved} role="status">
                  Save your <a href={Onboarding.path(:client)}>Desktop client settings</a>
                  before connecting Google.
                </p>
                <p>
                  Choose the intended Google identity in Google's browser flow. If you see an unverified-app warning, review it against your own project and personal-use eligibility before proceeding. If you decline, Gmail remains disconnected.
                </p>
                <p>
                  Successful consent returns to <a href={Onboarding.path(:calendar)}>optional Calendar setup</a>.
                  If consent is cancelled or fails, you return here to retry or continue without connecting.
                </p>
                <.actions
                  step={@step}
                  csrf_token={@csrf_token}
                  continue={!is_nil(@calendar_account)}
                  skip="Skip Gmail"
                />
              <% :calendar -> %>
                <p>
                  Add read-only agendas for your connected Google account, or skip Calendar and finish setup. Calendar is never enabled automatically.
                </p>
                <.calendar_status connection={@connection} />
                <form
                  :if={
                    @workspace && @calendar_account &&
                      (!@calendar_account.calendar_enabled || calendar_reconnect?(@calendar))
                  }
                  id="onboarding-calendar-connect"
                  action="/oauth/google/start"
                  method="post"
                  class="onboarding-form"
                >
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <input type="hidden" name="workspace_id" value={@workspace.id} />
                  <input type="hidden" name="expected_account_id" value={@calendar_account.id} />
                  <input type="hidden" name="capability" value="calendar" />
                  <input type="hidden" name="origin" value="onboarding" />
                  <p><strong>Google account:</strong> {@calendar_account.email}</p>
                  <p>
                    Choose this same account in Google. LOVELACE will request access to list your calendars and read events, retaining read-only Gmail access. It cannot create or change events.
                  </p>
                  <p>
                    Enable the
                    <.external href="https://console.cloud.google.com/apis/library/calendar-json.googleapis.com">
                      Google Calendar API
                    </.external>
                    in your existing project and add both read-only scopes from
                    <a href={Onboarding.path(:authentication)}>Authentication</a>
                    if you have not already done so.
                  </p>
                  <button class="workspace-action workspace-action-primary" type="submit">
                    {if calendar_reconnect?(@calendar),
                      do: "Authorize Calendar again",
                      else: "Enable read-only Calendar"}
                  </button>
                </form>
                <p>
                  Successful consent returns here so you can choose calendars before reviewing setup.
                  Cancelling or declining leaves your existing Gmail connection intact.
                </p>
                <p :if={@error == :calendars_saved} role="status">
                  Your calendar selection is saved.
                </p>
                <.calendar_picker
                  :if={@calendar_account && @calendar_account.calendar_enabled}
                  result={@calendar}
                  csrf_token={@csrf_token}
                  status_only={@calendar_status_only?}
                />
                <.actions
                  step={@step}
                  csrf_token={@csrf_token}
                  continue={!is_nil(@calendar_account) && @calendar_account.calendar_enabled}
                  skip="Skip Calendar"
                />
              <% :complete -> %>
                <.connection_status connection={@connection} />
                <.calendar_status connection={@connection} />
                <p :if={@connection == {:ok, nil}}>
                  Gmail is not connected. You can continue without Gmail; finishing this guide does not create a connection.
                </p>
                <p :if={@workspace}>
                  <a href={"/workspaces/#{@workspace.id}"}>Open {@workspace.name}</a>
                  to view the receiving workspace. Accounts remain separate, even when you add more later.
                </p>
                <p>
                  Google console settings were not independently verified by this guide. Connection and read status reflect only LOVELACE's saved observations; opening this page performs no provider check.
                </p>
                <p>
                  Add integrations later in <a href="/connections">Connections</a>.
                  The <a href="/onboarding/project">Google setup guide</a>
                  remains available whenever you need it.
                </p>
                <form id="onboarding-finish" action="/onboarding/complete" method="post">
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <input type="hidden" name="operation" value="finish" />
                  <div class="onboarding-actions">
                    <button class="workspace-action workspace-action-primary" type="submit">Finish setup</button>
                  </div>
                </form>
            <% end %>
          </div>
          <footer class="onboarding-footer">
            <p>
              Console links open a new tab. Check that the same Google Cloud project is selected in each tab.
            </p>
          </footer>
        </section>
      </main>
      <Layouts.brand id="first-run-brand" static />
    </Layouts.stage>
    """
  end

  attr :href, :string, required: true
  slot :inner_block, required: true

  defp external(assigns) do
    ~H"""
    <a href={@href} target="_blank" rel="noopener noreferrer">{render_slot(@inner_block)}<span class="sr-only"> (opens in a new tab)</span></a>
    """
  end

  attr :step, :atom, required: true
  attr :csrf_token, :string, required: true
  attr :skip, :string, required: true
  attr :continue, :boolean, default: true
  attr :submit_form, :string, default: nil
  attr :saved_client, :boolean, default: false

  defp actions(assigns) do
    ~H"""
    <form
      action={Onboarding.path(@step)}
      method="post"
      class="onboarding-actions onboarding-step-actions"
    >
      <input type="hidden" name="_csrf_token" value={@csrf_token} />
      <div :if={@continue} class="onboarding-continue-actions">
        <button
          type="submit"
          name="operation"
          value="continue"
          form={@submit_form}
          class="workspace-action workspace-action-primary"
        >
          Continue
        </button>
        <button
          :if={@saved_client}
          type="submit"
          name="operation"
          value="continue"
          class="workspace-action"
        >
          Use saved client
        </button>
      </div>
      <button type="submit" name="operation" value="skip" class="workspace-action">
        {@skip}
      </button>
    </form>
    """
  end

  attr :result, :any, required: true
  attr :csrf_token, :string, required: true
  attr :status_only, :boolean, default: false

  defp calendar_picker(assigns) do
    ~H"""
    <section
      id="onboarding-calendar-picker"
      class="onboarding-note"
      aria-labelledby="onboarding-calendar-picker-heading"
      data-onboarding-calendar
      data-workspace-id={calendar_identity(@result, :workspace_id)}
      data-account-id={calendar_identity(@result, :account_id)}
      data-generation={calendar_identity(@result, :generation)}
    >
      <h2 id="onboarding-calendar-picker-heading" tabindex="-1">Choose your calendars</h2>
      <p data-calendar-client-error role="alert" hidden>
        Calendar setup could not be updated. Reload this step to check your connection before retrying.
      </p>
      <p data-calendar-poll-stopped role="status" aria-live="polite" hidden>
        Calendar work may still be pending. Automatic status checks have stopped.
        Use Refresh calendar status to check again without requesting another Calendar read.
      </p>
      <%= case @result do %>
        <% {:ok, setup} when is_map(setup) -> %>
          <div
            data-calendar-progress
            data-loading={to_string(setup.loading)}
            data-autoload={
              to_string(
                !@status_only && setup.enabled && is_nil(setup.catalog_at) && !setup.loading &&
                  is_nil(setup.error)
              )
            }
            data-status-only={to_string(@status_only)}
          >
            <p :if={setup.loading} data-calendar-loading-message role="status">
              Loading your calendars… You can stay on this step.
            </p>
            <p :if={setup.error} role="status">{calendar_error(setup.error)}</p>
            <p :if={setup.truncated} role="status">
              Calendar results are partial because a bounded read limit was reached.
              Some calendars or events may not be included.
            </p>
            <p :if={setup.selection_truncated} role="status">
              Not all Google-selected calendars could be included. Choose up to 20 below.
            </p>
            <p :if={!setup.available? && !setup.loading && !setup.error}>
              Load the calendars available to this Google account, including shared calendars.
            </p>
            <p :if={setup.available? && setup.calendars == []}>
              No calendars are available for this account.
            </p>
            <form
              :if={setup.available?}
              id="onboarding-calendar-selection"
              action="/onboarding/calendar"
              method="post"
              class="onboarding-form"
            >
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <input type="hidden" name="operation" value="select_calendars" />
              <input type="hidden" name="workspace_id" value={setup.workspace_id} />
              <input type="hidden" name="account_id" value={setup.account_id} />
              <input type="hidden" name="generation" value={setup.generation} />
              <input type="hidden" name="calendar_ids[]" value="" />
              <fieldset disabled={setup.loading || setup.error == :reconnect}>
                <legend>Calendars shown in LOVELACE · choose up to 20</legend>
                <p>
                  Google-selected calendars are checked by default. Changes affect only LOVELACE.
                  Uncheck all to show none.
                </p>
                <label :for={calendar <- setup.calendars} class="setup-acknowledgement">
                  <input
                    type="checkbox"
                    name="calendar_ids[]"
                    value={calendar.id}
                    checked={calendar.id in setup.selected_ids}
                  />
                  <span>{calendar.name}</span>
                </label>
              </fieldset>
            </form>
            <div class="onboarding-calendar-actions">
              <button
                :if={setup.available?}
                id="onboarding-calendar-save"
                type="submit"
                form="onboarding-calendar-selection"
                class="workspace-action workspace-action-primary"
                disabled={setup.loading || setup.error == :reconnect}
              >Save calendar selection</button>
              <form
                id="onboarding-calendar-load"
                action="/onboarding/calendar"
                method="post"
                class="onboarding-form"
                data-calendar-load
              >
                <input type="hidden" name="_csrf_token" value={@csrf_token} />
                <input type="hidden" name="operation" value="refresh_calendars" />
                <input type="hidden" name="workspace_id" value={setup.workspace_id} />
                <input type="hidden" name="account_id" value={setup.account_id} />
                <input type="hidden" name="generation" value={setup.generation} />
                <input
                  :for={field <- ["from", "to", "date", "timezone"]}
                  type="hidden"
                  name={field}
                  value=""
                />
                <button
                  id="onboarding-calendar-load-button"
                  type="submit"
                  class="workspace-action"
                  disabled={
                    setup.loading || setup.error == :reconnect || calendar_cooling_down?(setup)
                  }
                >
                  {if setup.available?, do: "Refresh calendars", else: "Load calendars"}
                </button>
              </form>
            </div>
            <noscript>
              <p>Enable JavaScript to load calendars using this browser's local day.</p>
            </noscript>
            <p>
              <a
                id="onboarding-calendar-status-refresh"
                href={Onboarding.path(:calendar) <> "?status=1"}
                data-calendar-status
              >Refresh calendar status</a>
            </p>
          </div>
        <% _ -> %>
          <p role="status">
            Calendar selection is unavailable. Reload this step after checking your Google connection.
          </p>
      <% end %>
    </section>
    """
  end

  defp calendar_identity({:ok, setup}, key) when is_map(setup), do: Map.get(setup, key)
  defp calendar_identity(_, _), do: nil

  defp calendar_cooling_down?(%{cooldown_until: %DateTime{} = deadline}),
    do: DateTime.compare(deadline, DateTime.utc_now()) == :gt

  defp calendar_cooling_down?(_), do: false

  defp calendar_reconnect?({:ok, %{error: :reconnect}}), do: true
  defp calendar_reconnect?(_), do: false

  defp calendar_error(:reconnect), do: "Authorize Calendar again above to load your calendars."

  defp calendar_error(:rate_limited),
    do: "Google has temporarily limited Calendar reads. Wait five minutes before retrying."

  defp calendar_error(:keychain),
    do: "Calendar credentials are unavailable. Unlock LOVELACE again, then retry here."

  defp calendar_error(_), do: "The calendar list could not be updated. Try loading it again here."

  defp calendar_account({:ok, %{status: :ready} = account}), do: account
  defp calendar_account(_), do: nil

  attr :connection, :any, required: true

  defp calendar_status(assigns) do
    ~H"""
    <section
      id="onboarding-calendar-status"
      class="onboarding-note"
      aria-labelledby="onboarding-calendar-heading"
    >
      <h2 id="onboarding-calendar-heading">Optional Calendar</h2>
      <%= case @connection do %>
        <% {:ok, %{calendar_enabled: true, email: email}} -> %>
          <p>
            Calendar authorization is saved for {email}. This is not a fresh check of access or a successful agenda read.
          </p>
          <p>
            Agendas appear on Home and in your workspace after a successful read.
          </p>
        <% {:ok, %{status: :ready}} -> %>
          <p>Calendar is not enabled. You can keep Gmail without adding Calendar.</p>
        <% {:ok, nil} -> %>
          <p>
            Connect Gmail before enabling Calendar for the same Google account. <a href={
              Onboarding.path(:connect)
            }>Return to Connect Gmail</a>, or continue without Calendar.
          </p>
        <% {:ok, _} -> %>
          <p>
            Your Google account needs reconnection before Calendar can be enabled. <a href={
              Onboarding.path(:connect)
            }>Return to Connect Gmail</a>, or continue without Calendar.
          </p>
        <% {:error, _} -> %>
          <p role="status">
            Calendar connection status is unavailable. No access or successful read is being claimed. Try again after unlocking or skip Calendar.
          </p>
      <% end %>
    </section>
    """
  end

  attr :connection, :any, required: true

  defp connection_status(assigns) do
    ~H"""
    <section
      id="onboarding-connection-status"
      class="onboarding-note"
      aria-labelledby="onboarding-connection-heading"
    >
      <h2 id="onboarding-connection-heading">Gmail connection and first read</h2>
      <%= case @connection do %>
        <% {:ok, nil} -> %>
          <p>No Gmail account is connected to your chosen workspace.</p>
        <% {:ok, %{status: :reconnect}} -> %>
          <p>
            A saved Google account needs reconnection. Usable Gmail access is not confirmed. Manage it in <a href="/connections/gmail">Gmail connections</a>.
          </p>
        <% {:ok, account} -> %>
          <p>
            Google authorization has been saved for an account in your chosen workspace. This is not a fresh check of its grant.
          </p>
          <p :if={account.last_error || account.inbox_unread_error}>
            The last Gmail read reported a problem. Check the account's current status in Connections; this page does not retry provider work.
          </p>
          <p :if={!account.last_success_at && !account.inbox_unread_at}>
            The first successful Gmail read has not yet been confirmed. Open the inbox to request a read; it may still be waiting or unavailable.
          </p>
          <p :if={account.last_success_at || account.inbox_unread_at}>
            A Gmail read was last confirmed at <time datetime={
              DateTime.to_iso8601(account.last_success_at || account.inbox_unread_at)
            }>{Calendar.strftime(account.last_success_at || account.inbox_unread_at, "%Y-%m-%d %H:%M UTC")}</time>. This saved observation may be stale.
          </p>
          <p>
            <a href={"/accounts/#{account.id}/mail"}>Open this account's read-only inbox</a>. Reading in LOVELACE never marks messages as read in Gmail.
          </p>
        <% {:error, _} -> %>
          <p role="status">
            Connection status is unavailable. No connection or successful read is being claimed. Check <a href="/connections/gmail">Gmail connections</a>.
          </p>
      <% end %>
    </section>
    """
  end

  defp title(:workspace), do: "Create your first workspace"
  defp title(:project), do: "Create your Google project"
  defp title(:authentication), do: "Describe your consent application"
  defp title(:audience), do: "Choose your audience and publishing mode"
  defp title(:client), do: "Create a Desktop OAuth client"
  defp title(:connect), do: "Connect Gmail to your workspace"
  defp title(:calendar), do: "Add Calendar to your Google account"
  defp title(:complete), do: "Review your local setup"

  defp short_title(:workspace), do: "Workspace"
  defp short_title(:project), do: "Project"
  defp short_title(:authentication), do: "Authentication"
  defp short_title(:audience), do: "Audience"
  defp short_title(:client), do: "Client"
  defp short_title(:connect), do: "Gmail"
  defp short_title(:calendar), do: "Calendar"
  defp short_title(:complete), do: "Complete"

  defp error_message(:workspace),
    do: "Enter a workspace name of 1–64 characters. Your workspace could not be saved."

  defp error_message(:calendar_load),
    do: "Calendars could not be loaded. Check your Google connection and try again here."

  defp error_message(:calendar_selection),
    do:
      "The calendar selection could not be saved. Reload this step and choose up to 20 current calendars."

  defp error_message(:credentials),
    do:
      "Unable to save Google client settings. Check both values and that your dedicated vault is unlocked, then try again. Submitted values are not shown or retained in this form."

  defp error_message(:connection),
    do: "Google connection was not completed. Try again or continue without connecting."

  defp error_message(:calendar),
    do:
      "Calendar authorization was not completed. Your existing Gmail connection has not been removed. Try again or skip Calendar."

  defp error_message(_),
    do:
      "Unable to save local setup progress. Please unlock again; existing data has not been reset."
end
