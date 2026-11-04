# Read-only Gmail in LOVELACE

## Scope

Optional read-only Google Calendar agendas reuse these connections with separate,
explicit consent and independent Calendar freshness. See [CALENDAR.md](CALENDAR.md)
for scopes, selection, browser-local today, polling and shared disconnect semantics.

One local owner unlocks LOVELACE with a password. Google connections are **not**
owner identities. Connect Google once and attach that connection to one or more
workspaces. Each workspace can contain several accounts; each inbox, search,
conversation, cache, job and update remains account-scoped. There is no unified inbox.
Projects, sending, drafts and archive/read/label changes remain outside current scope.
Attachment lists appear in opened message details. Files are fetched only on demand, never
persisted in the mail cache, and limited to 5 MiB per file. Explicit downloads are available
for bounded attachment types; only JPEG, PNG, GIF and WebP receive inline previews. SVG,
HTML and other active document formats are never rendered inline. Downloads use an
owner-protected route, safe generic content type, forced attachment disposition and
`nosniff`; preview bytes use a separate raster-image allowlist. Attachment IDs must match
metadata from the cached, account-scoped thread, and connection generation is checked
again after provider fetch. Reading a conversation or fetching an attachment does **not**
mark it as read in Gmail.

This is a macOS-first integration. Automated tests use synthetic providers and vaults,
not real accounts or credential values. Follow the manual steps below to activate a new
installation yourself.

## 1. Local preparation

For a new installation, stop the server and run from a private checkout:

```sh
umask 077
brew install sqlcipher
bin/lovelace-sqlcipher mix deps.get
bin/lovelace-sqlcipher mix deps.clean --build exqlite
bin/lovelace-sqlcipher mix deps.compile exqlite --force
bin/lovelace-sqlcipher mix lovelace.keychain.build
bin/lovelace-sqlcipher mix lovelace.owner.setup
```

The wrapper requires SQLCipher **4.20.0**. Owner setup creates the encrypted schema
and dedicated password-unlocked file keychain; do not use ordinary plaintext SQLite
migration commands for this installation. Keep data directories private (`0700`) and
existing files owner-only (`0600`); `umask` affects new files only.

The owner task prompts twice with hidden input (12–1024 characters, at most 1024 UTF-8 bytes);
never pass passwords as command arguments. It does not start provider work. The database
key is independently generated and stored in the dedicated keychain, not derived from
the owner password. There is **no password recovery**: forgetting it permanently loses
access to the encrypted data.
Initial native creation may display a macOS authorization dialog for this dedicated
keychain; enter the same owner password there, never in shell arguments or chat.
If setup or authorization is interrupted, rerun owner setup with that password.
Native creation uses unpublished encrypted staging files until the random database key
is verified; interrupted unused staging files are retained, never substituted for a
previously initialized keychain.
Its private setup/creation markers preserve unfinished storage; initialized keys and
owner credentials are never replaced. Do not delete those markers to force setup.

For an existing plaintext installation, stop the application and run
`bin/lovelace-sqlcipher mix lovelace.vault.migrate` in a terminal. It verifies the owner
password and copies legacy credentials into the dedicated keychain. Separate exact
confirmations govern `CUT OVER`, `DELETE PLAINTEXT` and `DELETE LEGACY SECRETS`.
Original database files (including WAL) and legacy secrets are retained by default;
they remain exposed under their old protections until explicitly deleted. Migration
is journaled and resumable. Deletion is not guaranteed secure erasure of APFS snapshots,
backups or previously copied data. Never reset the database to migrate it.

The Keychain build requires Apple's Command Line Tools (`xcrun swiftc`). The generated
`priv/native/lovelace-vault` binary is ignored, not a committed executable. Build on
the target Mac before packaging a release; it must be included in the release's `priv`.
The helper uses Security.framework and explicit references to the dedicated
`lovelace.keychain-db`, without changing the user's default keychain or search list.
Gmail refresh tokens use the fixed **LOVELACE Gmail** service and an account UUID,
not an email address; Google client credentials use **LOVELACE Google OAuth**.
Secrets travel over bounded private stdin/stdout, never argv, temporary files, SQL
or job arguments. Access tokens are transient in memory. There is no runtime login
keychain fallback, plaintext fallback or iCloud synchronization. Legacy login
keychain access is confined to explicit terminal migration.

Explicit terminal setup and migration may enable macOS authorization UI (up to two
minutes per operation). Migration permits legacy item reads/deletions and approval of
the existing Database-key item after a helper rebuild; it never replaces that key.
Approval must allow the verified helper's later noninteractive reads. A `login`
keychain dialog uses that keychain's password, normally the macOS account password;
dedicated LOVELACE keychain dialogs use the owner password. Ordinary unlock,
background access and credential operations remain noninteractive and fail closed
on lock or access-control/signing mismatch.
Unlock the dedicated vault through LOVELACE's owner password flow.
Rebuilding/replacing an unsigned or ad-hoc-signed helper can change its Keychain
identity; do not grant all applications access to these items. The macOS file-keychain
APIs are deprecated; this is not a signed desktop installer or a validated cross-version
Keychain migration. Actual credential-store behavior needs attended validation on your Mac.

The helper uses deprecated custom-file `SecKeychain` APIs. Normal Lock and shutdown
lock that keychain, and every application startup relocks it before accepting an
unlock. After an abrupt crash, macOS's keychain daemon may still hold it unlocked
until the next startup; instant crash-time locking is not guaranteed.

## 2. Google Cloud setup

Use a dedicated project at <https://console.cloud.google.com/>:

1. Enable the **Gmail API**. Enable **Google Calendar API** too only when using the
   optional [Calendar integration](CALENDAR.md).
2. Configure **Google Auth Platform** branding and audience. Use **External** for
   personal Gmail or accounts from different organizations. Internal is limited to
   the project's own Google Workspace organization.
3. Add these Gmail scopes to the consent configuration (optional Calendar scopes are
   documented separately; Gmail-only authorization does not request them):
   - `openid`
   - `https://www.googleapis.com/auth/userinfo.email` (the console's canonical email scope)
   - `https://www.googleapis.com/auth/gmail.readonly`

   OAuth requests may spell the email scope as the OpenID alias `email`; LOVELACE accepts
   Google's returned `userinfo.email` form too. Do not add `userinfo.profile` just to
   obtain an email address.
4. Create an OAuth **Desktop app** client for this locally installed application.
   A Desktop client is public; its bundled client secret is not a security boundary.
   Do not use service-account/domain-wide delegation or the obsolete OOB flow.
5. Keep the client ID and client secret local. With the server stopped and the local
   owner/vault already configured, run `mix lovelace.google.configure` in a terminal.
   It prompts without echo for the owner password, client ID and client secret, and
   stores the pair in the dedicated LOVELACE keychain. It performs no provider calls
   and does not start background jobs. Runtime `GOOGLE_CLIENT_ID` and
   `GOOGLE_CLIENT_SECRET` environment variables are not read. Never paste credentials
   into chat, source, logs or shell history; do not commit downloaded client JSON.

LOVELACE uses `http://localhost:4000/oauth/google/callback` by default. A custom `PORT`
changes the callback port too. Desktop clients support loopback redirects without
registering each port. Google recommends literal loopback IPs and an available port;
LOVELACE deliberately uses its fixed **localhost** web origin so the initiating owner's
host-only session cookie and LiveView origin checks agree. Always open the application
as `http://localhost:PORT`; IP aliases redirect to the canonical homepage. The listener
remains `127.0.0.1`, never a LAN interface.

If you deliberately choose a **Web application** client instead, register the exact
localhost callback URL (scheme, host, port, path and trailing-slash behavior must match).
That client represents a separately configured confidential local server, not a
secret safely distributed inside a desktop application.

### Consent mode and refresh-token lifetime

`gmail.readonly` is a **restricted** scope. External applications in **Testing** with
Gmail grants generally receive refresh tokens that expire after **seven days**. Add
all intended Google identities as test users while testing. For durable personal use,
review Google's personal-use exemption, move the consent application to **In production**,
and reconnect; do not assume an old testing grant becomes permanent. Google documents
an exemption from mandatory verification for personal-use apps below its user threshold,
not an exemption from its data-use policy or Workspace administrator restrictions.
Unverified-app warnings and user caps can still apply. Managed accounts may require
administrator approval. Tokens can be revoked or expire for other reasons too.

## 3. Connect and read

Start with your private configuration injected:

```sh
dotenvx run --strict -f .env -- bin/lovelace-sqlcipher mix phx.server
```

The application starts locked: Repo, Oban and provider work remain stopped until
successful owner unlock. The first successful ordinary unlock in each application
startup may make the usual eligible, potentially billable scenery attempt when
enabled. Page loads and later lock/unlock cycles do not create another startup
attempt. Gmail never starts a browser or requests consent automatically.

1. Open `http://localhost:4000`, unlock to **Home**, choose **Workspaces**, enter a workspace,
   choose **Add integration**, then
   **Connect Google account**. Alternatively, open global **Connections → Gmail → Add Gmail account**
   and explicitly choose the receiving workspace in the modal, then **Connect Google account**.
   Cancel/Escape dismisses the modal without starting OAuth.
2. Choose the intended Google account and grant read-only mail access.
3. LOVELACE binds the verified UserInfo `sub` to the connection. Email is a display
   attribute, not its stable identity. Reconnect cannot silently select another account.
4. Open one account's inbox; search uses Gmail syntax across that account, including
   sent/archived mail. Spam/Trash follow Gmail's ordinary search behavior unless requested.
   Inbox rows show sender/date, subject and a short preview. Opening a conversation enters
   a dedicated plain-text reader: earlier messages collapse, the latest opens, and full
   sender/recipient/date details are expandable. Refresh preserves disclosure choices.
   **Back to results** restores the current search/page and opened row's scroll/focus within
   this live view. Account/thread paths and submitted search/page queries support browser
   Back/Forward, reload and copied links; queries consequently appear in browser history and
   copied URLs, but are filtered from Phoenix parameter logs. Parseable dates display
   in browser-local time; original headers remain in message details. Compact fetch freshness
   ages locally, with an expandable exact observation timestamp and explicit stale/error states.
5. In another workspace, use **Add integration → Add to workspace** to reuse the connection
   without reauthorizing. Each attached Gmail tile opens only that account's inbox.

Workspace card warnings reflect known connection problems, not a new live provider check.
Home shows each non-disconnected account once, with workspace labels and the unread inbox
conversation total from Gmail's INBOX label `threadsUnread` (not unread messages or a partial
page count). Unknown remains unavailable, not zero. The count has its own observation time
and failure state; stale counts remain visible and labeled. Unrelated page reads cannot
make an old count appear fresh. Rows open that account directly, even if unattached to a
workspace, without adding membership. Home never merges inboxes or shows message previews.
Global **Connections** (`/connections`) is a provider overview, with no workspace query or
workspace-return control. **Connections → Gmail** (`/connections/gmail`) lists reusable
accounts in compact rows with last known health,
reconnect and confirmed disconnect-everywhere controls. New Gmail connections start from
an **Add Gmail account** button/modal rather than a permanently expanded form. Reconnecting globally explicitly selects a
workspace and also adds the account there; workspace-local reconnect retains its workspace.

Authorization uses system-browser code flow, S256 PKCE, offline access, single-use
10-minute state bound to the unlocked owner session, and a fresh identity lookup.
Restarting during consent cancels the in-memory attempt safely; start again.
A denied or expired grant produces a reconnect state, not endless credential retries.
Successful Gmail consent returns directly to `/workspaces/:id` for the explicitly selected
receiving workspace; safe failure categories return to `/connections/gmail`. These are real
paths, not root-query navigation. Receiving-workspace fields in OAuth forms/state remain
membership intent, separate from global Connections navigation.

## Connection troubleshooting

For existing accounts, **Connections → Gmail → Check Keychain** performs an explicit,
local-only read for that account. The result contains only an allowlisted category
and observation time, never the credential. It does not contact Google, change
permissions, refresh mail or clear persisted sync errors/freshness. A readable token
is **not** proof that Google still accepts it. Checks are asynchronous, one at a time
per view, and discarded across connection-generation changes or leaving Connections.

- `locked`: the dedicated vault is locked, or the native helper reports authentication
  failure or interaction denied. An unlocked vault can still have an item-access failure.
- `timeout`: the helper did not complete within its existing bounded deadline.
- `not_found`: no credential was found for that account; reconnect Google.
- `unavailable`: helper/credential access could not be established; this does not
  prove that the item is absent or that Google is offline.
- `invalid_account` / `invalid_value`: the adapter rejected the identifier/value.

Review **About Keychain access** in Connections before changing anything. Rebuilding
the `lovelace-vault` helper can change its signing identity. Do not delete credentials,
grant all applications access, broaden partition ACLs, or repeatedly rebuild as an
attempted access repair. Diagnostics do not repair signing/ACLs or expose raw macOS
OSStatus values; exact native denial recovery remains a manual investigation.

The login/default keychain is **legacy-only**, accessed solely by explicit terminal
migration. Old helper access entries or prior login-keychain repair procedures are not
instructions for the current vault. If a legacy credential cannot be read during migration,
investigate only that legacy item and verified helper identity; do not broaden its ACLs
or move current credentials back to the login keychain.

`userinfo.email` is the canonical console scope for the OAuth alias `email`; both
forms are already supported. If consent completes but LOVELACE rejects the connection,
the flash and terminal now report an allowlisted stage/category (session/state,
token exchange, identity, account binding, offline token, Keychain or persistence).
Share only that safe category if needed, never a callback URL, code, state, token,
client secret or raw Google response.

A corrected native-helper stdin bug previously caused short JSON requests to wait
for 4096 bytes/EOF until the watchdog expired. The helper now uses bounded POSIX reads
and processes newline frames with stdin still open. After updating this source, run
`mix lovelace.keychain.build` and restart LOVELACE with dotenvx, then start a **fresh**
connection attempt. Old binaries do not inherit Swift source changes. Restarting clears
pending OAuth state, so do not reuse an earlier callback URL. A macOS-only regression
compiles/runs the real helper with invalid inputs that cannot reach a credential operation.
Unreadable prior credentials now fail closed before any overwrite; a read error is not
interpreted as an absent credential during rollback.

## Retention, freshness and removal

- Fetch only requested pages and opened threads. Pages contain at most 20 conversation
  summaries. No full mailbox download, local search index, history cursor or push service.
- Persist fetched data for at most seven days, bounded to **120 entries / 25 MiB per
  account**; individual cached results are capped at 5 MiB. Oldest fetched entries are
  evicted first. Expiry is enforced on reads and the minute sweep while the app runs;
  no cleanup occurs while the app is stopped. This is logical record deletion, **not
  forensic erasure** of SQLite pages, WAL files, backups or browser-rendered copies.
- The business-data cache is encrypted in SQLCipher SQLite using the independently
  generated key held in the dedicated vault. The `.vault` directory also contains the
  keychain and an empty plaintext infrastructure-lock SQLite file, not business data.
  Encryption does not protect an unlocked process, browser-rendered copies or code
  running as your OS user. Protect permissions, FileVault and backups; retained legacy
  plaintext databases and sidecars remain exposed until explicitly removed.
- Plain-text MIME is preferred; HTML-only mail is conservatively converted to text.
  All output is HEEx-escaped. No HTML rendering, scripts, automatic URL requests, remote
  external images or automatic attachment fetches. Opening a conversation lists bounded
  attachment metadata; previews fetch only allowlisted raster formats and downloads are
  explicit. Attachment bytes are not retained in SQLite. Oversized files/threads fail
  safely instead of rendering partial content. Current MIME text expects UTF-8.
- Oban **2.24.2**, Apache-2.0, uses its bundled SQLite Lite engine. A minute cron sweep
  queues overdue per-account polls, targeting a three-minute interval, queue concurrency 1.
  It refreshes the first inbox page and independently reads the INBOX label's unread
  conversation count; open account-scoped views refresh through PubSub.
  Other cached searches/pages/threads refetch on demand. This is polling, not a complete
  history-based mailbox reconciliation. Sleep, rate limits, queue backlog and network
  failures can increase delay. The app does not execute while stopped/asleep.
- A known 429 holds provider admission for five minutes across polling, queued retries,
  automatic view refreshes, searches/threads and manual Refresh. Cached results retain
  the rate-limit/error and stale status; opening another view does not erase a known
  failure or extend the cooldown. Work already in flight cannot clear a newer cooldown.
- Jobs contain only account ID and connection generation. Pending work survives restart;
  Lifeline rescues abandoned work after five minutes, and the sweep discovers overdue
  accounts after restart/resume. Each job has at most three attempts. Provider 429 responses
  impose a five-minute wait; automatic retries are for read operations only.
- Count observations are generation-fenced and cleared on reconnect/disconnect. Their
  separate errors preserve known values and observation times; a failed count read does
  not masquerade as a successful count update. Home's freshness label ages locally and
  marks counts stale after three minutes, including across hidden tabs/system sleep.
- Cache and errors show timestamps and stale status. **Refresh** explicitly requests
  another read. Explicit global **Lock** revokes sessions and stops Repo, Oban and
  provider work; no polling or cache cleanup runs while locked. Visual idle/Escape
  scenery mode is not a lock and lets already authorized background work continue.
- **Remove from workspace** in an integration tile's management menu removes one workspace association. It does not clear the shared cache,
  delete credentials, revoke Google access or stop polling that reusable connection.
- A remaining recovery limitation: a first connection can leave an unindexed Keychain
  item if the process dies after its credential write but before the identity commits,
  or if persistence and compensating deletion both fail. The token remains in Keychain,
  never SQLite, but normal disconnect cannot discover that orphan. No automatic orphan
  reconciliation is implemented; review the **LOVELACE Gmail** service in Keychain Access
  and Google application access after an interrupted/failed connection. Do not share item
  values. Successful-return failure paths attempt restoration/deletion and report failures.
- **Disconnect everywhere** in global **Connections** fences in-flight work, clears all workspace associations and
  cached records, deletes the Keychain item and attempts Google revocation. Local cleanup
  and revocation outcomes are reported separately. Failed credential deletion remains
  visible for retry; failed/uncertain revocation needs review at
  <https://myaccount.google.com/connections>. Google revocation can affect the application's
  associated grants; it is not a Gmail message mutation. Minimal disconnected identity
  metadata remains to reuse the stable connection ID on reconnection.

## Security and instrumentation decision

There is **no external telemetry exporter configured**. The user explicitly chose to
retain stock Bandit after reviewing this distinction:

- [Bandit 1.14.1 documents a `Plug.Conn` in HTTP request telemetry](https://hexdocs.pm/bandit/1.14.1/Bandit.Telemetry.html).
  It does **not** promise to strip request headers/query strings, and emits the initial
  event before endpoint middleware. OAuth codes/state, session headers and potentially
  buffered password bytes can therefore be visible to trusted code in the same BEAM.
  No external transmission or persistent logging was established. This is an accepted
  **local-only instrumentation exception**, not a claim that stock Bandit is payload-free.
  Do not install payload loggers, tracing/export agents or dump raw conn/socket metadata
  without a new privacy review. A stronger no-in-process-payload requirement needs a
  server-level upstream fix or separately approved dependency vendoring.
- Early password and OAuth callback plugs avoid *additional* Phoenix router/endpoint
  exposure. Normalized aliases cannot bypass them. Passwords/codes are not accepted in
  normal credential-bearing query-based forms, and logs filter sensitive parameter names.
- Provider HTTP uses private passive Mint, no Req/Finch payload telemetry, redirects,
  proxies or automatic retries. Fixed Google hosts/paths, TLS verification, byte/deadline
  caps and allowlisted errors apply. Test builds reject ordinary real-provider connections
  and native credential operations.
- Repo ORM defaults suppress raw SQL logging and Ecto query telemetry because those
  events contain mail parameters **and returned rows**. Do not bypass defaults with raw
  SQL or per-query overrides for mail. UI bodies live in bounded ephemeral render storage,
  not socket assigns. Standard browser/server instrumentation is not certified free of
  all private content; the explicit Bandit exception above remains.
- Owner sessions are digest-only server records, 12-hour absolute expiry, rate-limited
  unlock, CSRF protection, regenerated login sessions, and revocation/disconnection on lock.
  Escape/inactivity is scenery mode, **not** a security lock. Use **Lock** explicitly.
- Development Tidewave retains its pre-existing local code/SQL capability. Owner unlock
  does not sandbox development tooling. Never expose the application or Tidewave remotely.
- Use one running application instance for Gmail. Credential coordination and LiveView
  payload storage are local to that BEAM; scenery's separate multi-BEAM filesystem
  protocol does not make Gmail a distributed integration.

## Verification limits

Synthetic tests do not certify real-provider unread conversation totals/recovery, native
Keychain permissions, helper signing or cross-version credential migration. Validate these
manually when relevant; a previous successful connection is not standing permission for
provider operations or credential changes. Connected A→B→A delayed-result and rotating-token
reconnect/disconnect interleavings are not exhaustively tested. Keep account/generation
fences and use synthetic regression cases when changing those paths.

## References

- [Google installed-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
- [OAuth token expiration](https://developers.google.com/identity/protocols/oauth2#expiration)
- [Personal-use verification exceptions](https://support.google.com/cloud/answer/13464323)
- [OpenID Connect / UserInfo](https://developers.google.com/identity/openid-connect/openid-connect)
- [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- [Gmail thread list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.threads/list)
- [Oban Lite engine](https://hexdocs.pm/oban/2.24.2/Oban.Engines.Lite.html)
- [Apple Security item API](https://developer.apple.com/documentation/security/secitemadd(_:_:))
