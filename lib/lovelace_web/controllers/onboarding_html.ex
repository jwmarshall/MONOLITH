defmodule LovelaceWeb.OnboardingHTML do
  use LovelaceWeb, :html

  alias Lovelace.Onboarding

  def show(assigns) do
    ~H"""
    <Layouts.stage id="onboarding-stage" class="stage-static" background={@background} static>
      <a class="workspace-skip-link" href="#main-content">Skip to setup</a>
      <main
        id="main-content"
        class="workspace-glass owner-glass onboarding-glass"
        aria-labelledby="onboarding-heading"
      >
        <section class="onboarding-content">
          <header>
            <p class="onboarding-eyebrow">LOVELACE · Google setup</p>
            <h1 id="onboarding-heading">{title(@step)}</h1>
            <p>Your place is saved locally when you continue. You control every Google change.</p>
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
          <p :if={@error} id="onboarding-error" class="onboarding-error" role="alert">
            {error_message(@error)}
          </p>
          <div class="onboarding-instructions">
            <%= case @step do %>
              <% :project -> %>
                <p>
                  Use your own Google Cloud project for this private, read-only Gmail connection. LOVELACE will not create or change a Google project for you.
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
                  Only Gmail is needed here. Calendar is optional later; do not enable services or billing just for this guide.
                </p>
                <.advance step={@step} csrf_token={@csrf_token} label="Continue to authentication" />
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
                    and add the three scopes below, then save.
                  </li>
                </ol>
                <ul class="onboarding-scopes" aria-label="Required Gmail scopes">
                  <li><code>openid</code></li>
                  <li><code>https://www.googleapis.com/auth/userinfo.email</code></li>
                  <li><code>https://www.googleapis.com/auth/gmail.readonly</code></li>
                </ul>
                <p>
                  The console uses <code>userinfo.email</code>; OAuth may show its equivalent
                  <code>email</code>
                  alias. Do not add <code>userinfo.profile</code>, write scopes, service accounts, or domain-wide delegation.
                </p>
                <.advance
                  step={@step}
                  csrf_token={@csrf_token}
                  back={:project}
                  label="Continue to audience"
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
                <.advance
                  step={@step}
                  csrf_token={@csrf_token}
                  back={:authentication}
                  label="Continue to Desktop client"
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
                  <div class="onboarding-actions">
                    <a href={Onboarding.path(:audience)}>Back</a>
                    <button type="submit" class="owner-submit">Save client and continue</button>
                  </div>
                </form>
                <.advance
                  :if={@progress && @progress.credentials_saved}
                  step={@step}
                  csrf_token={@csrf_token}
                  label="Continue with previously saved client"
                />
              <% :connect -> %>
                <p>
                  Connect the intended Google account to your starter workspace. Google authorization starts only when you press the button below.
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
                  <p>
                    <strong>Destination:</strong> {@workspace.name} (your Personal starter workspace).
                  </p>
                  <p>
                    <strong>Access:</strong>
                    read-only Gmail plus your Google identity and email address. LOVELACE cannot send, archive, delete, or mark messages as read.
                  </p>
                  <button class="owner-submit" type="submit">Connect Google account</button>
                </form>
                <p :if={!@progress || !@progress.credentials_saved} role="status">
                  Save your <a href={Onboarding.path(:client)}>Desktop client settings</a>
                  before connecting Google.
                </p>
                <p>
                  Choose the intended Google identity in Google's browser flow. If you see an unverified-app warning, review it against your own project and personal-use eligibility before proceeding. If you decline, Gmail remains disconnected.
                </p>
                <p>
                  Successful consent returns to the receiving workspace. Use
                  <strong>Finish setup</strong>
                  there, or return to <a href={Onboarding.path(:complete)}>this guide's completion page</a>. A failed or cancelled connection returns to Connections; this guide remains available at <a href="/onboarding">/onboarding</a>.
                </p>
                <.advance
                  step={@step}
                  csrf_token={@csrf_token}
                  back={:client}
                  label="Review completion"
                />
              <% :complete -> %>
                <.connection_status connection={@connection} />
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
                  You can return to <a href="/onboarding">Google setup</a>
                  at any time, or manage accounts in <a href="/connections/gmail">Connections → Gmail</a>.
                </p>
                <form id="onboarding-finish" action="/onboarding/complete" method="post">
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <input type="hidden" name="operation" value="finish" />
                  <div class="onboarding-actions">
                    <a href={Onboarding.path(:connect)}>Back to connection</a>
                    <button class="owner-submit" type="submit">Finish setup and open Home</button>
                  </div>
                </form>
            <% end %>
          </div>
          <footer class="onboarding-footer">
            <p>
              Console links open a new tab. Check that the same Google Cloud project is selected in each tab.
            </p>
            <form :if={@step != :complete} action="/onboarding/connect" method="post">
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <input type="hidden" name="operation" value="continue" />
              <button type="submit" class="onboarding-skip">Continue without adding Gmail</button>
            </form>
          </footer>
        </section>
      </main>
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
  attr :label, :string, required: true
  attr :back, :atom, default: nil

  defp advance(assigns) do
    ~H"""
    <form action={Onboarding.path(@step)} method="post" class="onboarding-actions">
      <input type="hidden" name="_csrf_token" value={@csrf_token} />
      <input type="hidden" name="operation" value="continue" />
      <a :if={@back} href={Onboarding.path(@back)}>Back</a>
      <button type="submit" class="owner-submit">{@label}</button>
    </form>
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
          <p>No Gmail account is connected to your Personal starter workspace.</p>
        <% {:ok, %{status: :reconnect}} -> %>
          <p>
            A saved Google account needs reconnection. Usable Gmail access is not confirmed. Manage it in <a href="/connections/gmail">Connections → Gmail</a>.
          </p>
        <% {:ok, account} -> %>
          <p>
            Google authorization has been saved for an account in your Personal starter workspace. This is not a fresh check of its grant.
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
            Connection status is unavailable. No connection or successful read is being claimed. Check <a href="/connections/gmail">Connections → Gmail</a>.
          </p>
      <% end %>
    </section>
    """
  end

  defp title(:project), do: "Create your Google project"
  defp title(:authentication), do: "Describe your consent application"
  defp title(:audience), do: "Choose your audience and publishing mode"
  defp title(:client), do: "Create a Desktop OAuth client"
  defp title(:connect), do: "Connect Gmail to your workspace"
  defp title(:complete), do: "Review your local setup"

  defp short_title(:project), do: "Project"
  defp short_title(:authentication), do: "Authentication"
  defp short_title(:audience), do: "Audience"
  defp short_title(:client), do: "Desktop client"
  defp short_title(:connect), do: "Connect Gmail"
  defp short_title(:complete), do: "Complete"

  defp error_message(:credentials),
    do:
      "Unable to save Google client settings. Check both values and that your dedicated vault is unlocked, then try again. Submitted values are not shown or retained in this form."

  defp error_message(_),
    do:
      "Unable to save local setup progress. Please unlock again; existing data has not been reset."
end
