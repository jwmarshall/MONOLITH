# Read-only Google Calendar in LOVELACE

## Scope and setup

Calendar is optional on an existing Google/Gmail connection. Home and workspace agendas
remain **per account**, never a merged calendar. This slice shows browser-local **today**:
time, title, calendar name, all-day/ongoing labels and an explicit link back to Google
Calendar. It does not create/edit events, RSVP, join meetings, fetch attachments, render
descriptions/HTML or load remote imagery. Repeating events are expanded by Google.

1. Enable the **Google Calendar API** in the same Google Cloud project used for Gmail.
2. Add these read-only scopes to its consent configuration, retaining the existing
   OpenID/email/Gmail scopes:
   - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
   - `https://www.googleapis.com/auth/calendar.events.readonly`
3. Apply the additive migrations with the existing server stopped:
   `LOVELACE_STAGE_ENABLED=false mix ecto.migrate`. Never reset a private database.
4. Open **Connections → Calendar**. For an existing Google account, choose a receiving
   workspace and explicitly authorize Calendar. This reuses the same Google subject and
   Keychain item, not a second identity or owner login. Choosing another Google identity
   is rejected. Granting Calendar also retains read-only Gmail access.
5. Consent returns directly to `/connections/calendar`. Google's selected calendars seed
   the LOVELACE selection, including shared calendars. Use the checkboxes there to override
   the selection locally.
   An empty selection is valid; it means no calendars selected, not no events in Google.

Calendar consent is never requested automatically. Denying the optional consent leaves
an existing Gmail connection intact. A normal Gmail reconnect disables Calendar locally;
explicitly authorize Calendar again afterward. Calendar failures have their own health and
freshness, rather than overwriting Gmail's unread count or sync errors. A global Google
credential failure can still require reconnecting the shared connection.

The Google setup, testing-mode token lifetime, local-only OAuth flow, owner session
security and Keychain/signing limitations in [GMAIL.md](GMAIL.md) also apply. No native
helper rebuild or credential permission repair is needed for Calendar. Do not paste
credentials, OAuth callback URLs or real calendar contents into tests or reports.

## Day, freshness and bounds

The browser sends today's local midnight and the next local midnight as UTC instants,
with a local date and timezone label. DST days are not assumed to last exactly 24 hours.
Timed events overlap that interval; all-day events use inclusive start and exclusive
end dates. Ongoing and multi-day events are included. No local timezone database or
new dependency is required. The day is rechecked on a timer and visibility/resume events.

A connection retains one browser-day context at a time. Browsers in different timezones
may replace that context; a view never presents a different context's events as its own.
Polling targets three minutes via the existing minute Oban sweep while LOVELACE runs.
It stops requesting an expired day until a browser supplies the next day. Sleep, network
failures and queue backlog delay updates; nothing runs with the computer/app stopped.
Manual Refresh requests another bounded read, not instant or push delivery. Known rate
limits impose a five-minute Calendar cooldown, including manual Refresh.

Work is bounded to 100 listed calendars, 20 selected calendars, 100 expanded events per
calendar and 500 retained agenda events, within a 512 KiB payload bound. Provider pages
beyond these limits are not silently represented as complete: the UI labels partial
results. Google-selected calendars beyond the selection bound require a smaller explicit
selection. No local full-calendar mirror, history index or push service is introduced.
API time bounds are widened before exact local-day filtering to account for all-day
entries whose calendar timezone differs from the browser's.

The account-scoped cache contains minimal event text in **unencrypted SQLite**, retained
for at most 24 hours and never served after expiry. The running sweep performs logical
cleanup; this is not forensic erasure from SQLite pages/WAL/backups or browser copies.
Owner unlock does not encrypt data. Protect OS permissions, FileVault and backups.
Refresh failures retain known observations with stale/error labeling and unchanged
observation timestamps. Unknown/loading/error are not an empty successful agenda.

Jobs contain only account ID, connection generation and context revision. Account and
revision fences discard late results after reconnect, disconnect, day or selection changes.
Titles/calendar names are untrusted escaped text. Links are allowlisted HTTPS Google
Calendar destinations and are followed only by an explicit click.

## Removal and verification

Removing an account from a workspace removes only that workspace association. It does
not disable the reusable Calendar/Gmail connection or revoke Google access. **Connections
→ Gmail → Disconnect everywhere** fences both integrations, clears their local caches and
workspace associations, deletes the shared Keychain credential and attempts Google
revocation. Revoking the shared grant can affect both services; Calendar does not expose
an independent destructive revocation control.

Automated tests use synthetic provider/vault responses and disposable browser data.
They do not verify your Google consent configuration, shared-calendar permissions,
real event completeness or native Keychain access. Real authorization remains an explicit
manual setup step. See [DEVELOPMENT.md](DEVELOPMENT.md) for the check/browser commands.
