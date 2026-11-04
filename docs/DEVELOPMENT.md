# LOVELACE development and testing

LOVELACE is the project name, always uppercase in prose and UI. The OTP app is
`:lovelace`, modules use `Lovelace`/`LovelaceWeb`, and the Tailwind/esbuild profile is `lovelace`.
Sources live in `lib/lovelace/` and `lib/lovelace_web/`; local databases use `lovelace_*.db`.
The default UI theme is `sea-glass`. See the [visual and interaction contract](UI_CONTRACT.md).

## Local setup

Use the runtime versions in `.tool-versions`. Managed local storage requires macOS,
Apple's Command Line Tools, `pkg-config`, and SQLCipher **4.20.0** (not ordinary SQLite).
The native helper is `priv/native/lovelace-vault`; rebuild it after native-helper changes.

For a **new installation with no existing local data**, run:

```sh
asdf install                 # if these runtimes are not already installed
brew install sqlcipher pkg-config
bin/lovelace-sqlcipher mix setup
bin/lovelace-sqlcipher mix deps.clean --build exqlite
bin/lovelace-sqlcipher mix deps.compile exqlite --force
bin/lovelace-sqlcipher mix lovelace.keychain.build
bin/lovelace-sqlcipher mix lovelace.owner.setup
bin/lovelace-sqlcipher mix phx.server
```

`mix setup` fetches dependencies and installs/builds the Mix-managed Tailwind and
esbuild binaries; it does **not** create, migrate, seed or reset managed storage.
The explicit Exqlite rebuild replaces any cached ordinary-SQLite native build.
Use `bin/lovelace-sqlcipher` for Mix commands so native builds link SQLCipher;
managed startup checks the actual SQLCipher version and fails closed if unavailable.
Initial setup needs network access and native build tools. No npm install, Docker,
separate database service, or Google credentials are required. Node is needed for
the JavaScript hook tests in `mix check`, not asset building.

Owner setup, vault migration and Google credential configuration load
`config/runtime.exs` before resolving storage, without starting LOVELACE or its queues.
For production maintenance, supply the same `MIX_ENV=prod`, `DATABASE_PATH` and
`SECRET_KEY_BASE` as normal production startup; never let maintenance select another
installation's database.

Owner setup requires a local terminal, prompts without echo (no password arguments),
and creates the encrypted schema and dedicated password-unlocked macOS file keychain,
separate from the login keychain. The independently generated SQLite encryption key
is stored in that keychain, not derived from the owner password. Setup refuses unrelated
existing storage: use the stopped migration procedure below instead. Native creation may
show a macOS authorization dialog for the dedicated keychain; use the same owner password.
Only explicit terminal setup/migration can enable that UI; ordinary unlock and background
access remain noninteractive. Cancelled/interrupted setup retains private markers and
resumes by rerunning owner setup with the original password, without replacing an owner
or initialized database key. Never delete markers to force a reset.
Creation publishes the final keychain only after its random database key is verified.
An interruption before publication may leave unused encrypted `.keychain-creating-*`
files beside the private marker; retry does not overwrite an initialized keychain.
**There is no password reset or recovery: forgetting the password permanently loses
access to the encrypted data.**

Every server startup is locked. Open <http://localhost:4000> and unlock with the owner
password to start the protected Repo, Oban queues and provider work. Explicit **Lock**
globally stops that work, closes the Repo and locks the keychain; Escape/visual idle
only changes scenery and continues work. Normal shutdown locks the keychain. After
an abrupt crash the macOS daemon may retain an unlocked keychain until startup relocks
it; do not assume an instantaneous crash lock.
Stop the server with Ctrl-C (twice if prompted), or use
`bin/lovelace-sqlcipher iex -S mix phx.server` for an interactive Elixir shell.

To connect an account, follow the [Gmail setup guide](GMAIL.md); optionally add
[Google Calendar](CALENDAR.md). Neither is connected by local setup alone.
Scenery generation is optional; see [stage-designer setup](STAGE_DESIGNER.md)
before enabling potentially billable requests.

The server binds to `127.0.0.1:4000`; `PORT=4001 bin/lovelace-sqlcipher mix phx.server` changes the port.
Keep it local: owner unlock does not make network exposure safe. Development-only
[Tidewave](#tidewave-safety) can execute code and SQL; never expose it through a tunnel.

### Existing plaintext data: stopped terminal migration

Stop **every** LOVELACE instance before upgrading/cutover; this procedure cannot
secure an already-running old instance. Install the prerequisites and rebuild Exqlite
and the native helper as above, but do **not** run owner setup against existing data.
With all servers stopped, run in a separate local terminal:

```sh
bin/lovelace-sqlcipher mix lovelace.vault.migrate
```

The task requires `STOPPED`, verifies the existing owner password through hidden input,
exports to a separate encrypted database, verifies schema/data and correct/no/wrong-key
behavior, and copies known legacy credentials into the dedicated keychain. It requires
the exact `CUT OVER` confirmation before replacing the active database. Plaintext
originals, including SQLite sidecars/WAL, and legacy credentials are retained by default;
`DELETE PLAINTEXT` and `DELETE LEGACY SECRETS` are separate optional confirmations.
Retained plaintext backups are still exposed and need private handling.

An interrupted migration keeps a private journal and fail-closed startup marker:
rerun the same task to resume; never remove the marker or rename sidecars manually.
Only start the updated server after successful completion; startup still requires
owner unlock. File deletion is not secure erasure on APFS/SSDs and does not remove
snapshots, Time Machine copies, old backups or exported environment files. There is no
recovery path for a forgotten vault password. Never use `ecto.setup`, `ecto.reset`,
unkeyed Repo startup or manual file replacement to initialize or recover managed data.

If credential copying stops, keep every server stopped and preserve the migration
marker, journal, keychain and originals. The older `Credential copy conflict/unavailable`
message does not distinguish access denial from an actual differing value. The current
helper reports locked login storage, required/denied authorization, unavailable legacy
storage, timeout and genuine value conflicts separately. A conflict never authorizes
overwriting or deleting either credential.

After explicitly rebuilding the helper with `bin/lovelace-sqlcipher mix lovelace.keychain.build`,
rerun migration with the same configuration and owner password to resume. Rebuilding
can change the helper's Keychain identity. Only explicit migration may request
macOS approval for legacy reads and the **existing** Database-key item; it never
replaces that key. Verify the helper path before approving it. Choose **Always Allow**
only for the verified helper when persistent item access is required: migration checks
ordinary UI-disabled access before proceeding. A `login` keychain dialog uses that
keychain's password (normally the macOS account password), not the LOVELACE owner
password. A dedicated LOVELACE keychain dialog uses the owner password.

The database's `.vault` directory contains the dedicated keychain and an empty
plaintext infrastructure-lock SQLite file, not plaintext business tables. Keep the
database, keychain and any retained migration originals private.
Native keychain lifecycle verification is attended and separately opt-in; default checks
never post an authorization dialog. On macOS, run:

```sh
bin/lovelace-sqlcipher mix test test/lovelace/integrations/keychain_helper_io_test.exs --include attended_keychain
```

This builds a disposable helper with login-keychain migration code compiled out and
uses only disposable keychains. The test password is `synthetic diagnostic password`;
use it only for the named disposable keychain. The check exercises interrupted creation,
resumption, independent database-key persistence, and ten lock/unlock cycles.

Actual item-authorization recovery is a separate attended opt-in:

```sh
LOVELACE_KEYCHAIN_AUTHORIZATION_SMOKE=1 bin/lovelace-sqlcipher mix test test/lovelace/integrations/keychain_helper_io_test.exs --only authorization_smoke
```

It uses only disposable keychains and the same `synthetic diagnostic password`.
Approve only the named disposable helper; Database-item recovery requires persistent
**Always Allow** approval and then verifies the unchanged key through an ordinary
noninteractive read. Default checks never run these dialogs or access login credentials.

## Namespace and local data

Use `:lovelace` for configuration/environment lookups and `Lovelace`/`LovelaceWeb`
for application/web modules. The session cookie is `_lovelace_key`; existing browser
sessions start fresh after the rename. No signing secrets were rotated for the rename.

The local development and test databases were carried forward using SQLite's backup
API, including any WAL state, and verified with `PRAGMA quick_check`. Private rollback
copies of the original files are under the ignored `tmp/name-change-backups.DTpCBR/`
directory (`dev.db` and `test.db`, with sidecars if present). Keep them private; do not
use `mix ecto.reset` as a rename or recovery procedure. Production still uses the
explicit `DATABASE_PATH`; no production data was migrated.

Obsolete application/colocated build output was removed and assets rebuilt, rather
than renaming compiled BEAM files. Stop the server and restart after namespace changes;
hot reload is not an application-identity migration. Git hosting metadata and the
checkout folder name are separate from application identifiers and were not changed.

## Installed baseline

| Dependency | Role | Scope |
| --- | --- | --- |
| `ash`, `ash_sqlite`, `ash_phoenix` | Resources/domains/actions/policies, SQLite persistence, Phoenix forms | Runtime |
| `ash_sql` | Shared Ash SQL query planning | Runtime; locked to 0.8.7; releases before 0.8.6 are retired for an Ecto query-cache defect |
| `simple_sat` | Pure-Elixir SAT solver required by the first production Ash policies | Runtime |
| `ash_authentication`, `ash_authentication_phoenix` | Single local owner unlock | AshAuthentication password strategy; terminal-only setup |
| `req` | HTTP request/response contracts; built-in `Req.Test` stubs/expectations | Runtime; test utilities used in tests |
| `mint` | Private unpooled Gemini and Google transport, avoiding credential-bearing Finch telemetry | Runtime; pinned direct dependency |
| `oban` | Durable Gmail/Calendar polling and tracked Gemini scenery with bundled SQLite Lite engine | Runtime; 2.24.2, concurrency 1, cron/Lifeline/pruning |
| `exqlite` | SQLCipher binding for encrypted storage and private cross-BEAM filesystem exclusion handles | Runtime; explicit direct dependency linked to SQLCipher 4.20.0 |
| `vix` | Strict JPEG pixel decoding through libvips; original provider bytes retained | Runtime; native dependency |
| `credo`, `ash_credo` | General and Ash-aware static analysis | Dev/test, not started at runtime |
| `sobelow` | Phoenix security scanning | Dev/test, not started at runtime |
| `mix_audit` | Advisory database checks via `mix deps.audit` | Dev/test, not started at runtime |
| `igniter` | Reviewable code generation and project patching | Dev/test, not started at runtime |
| `usage_rules` | Dependency documentation/agent guidance | Dev, not started at runtime |
| `tidewave` | Agent runtime inspection/MCP; code and SQL execution | Dev only |

ExUnit, ConnTest, LiveViewTest, SQL Sandbox, `Ash.Test`, and `Ash.Generator` provide
the initial test toolkit. StreamData is already transitive through Ash; no additional
factory library is installed. See `mix.lock` for exact versions.

## Vendored animation assets

Topbar **3.0.0** supplies the existing LiveView navigation/form progress indicator
through `assets/js/app.js`'s local `assets/vendor/topbar.js` import. The source was
verified byte-for-byte against the SHA-512-verified npm archive and its immutable
upstream Git commit before pinning. Topbar is **MIT**; its complete permission,
copyright and warranty/liability notice is retained in `topbar.LICENSE.txt` and
an appended esbuild-preserved legal comment. That comment is the only local source
change. Keep the full notice in distributed bundles (and ship any legal sidecars
if the build policy changes), not merely the short upstream `@license MIT` header.
See [Topbar provenance and updates](../assets/vendor/topbar.README.md) for exact
artifact/commit URLs, upstream/local checksums, license-text provenance and the
intentional verification/update procedure. ExUnit pins source, license and package
metadata, and verifies the upstream bytes and complete embedded notice. No runtime
retrieval or npm installation is introduced. Review Topbar advisories separately;
`mix audit` is Hex-scoped. Existing GSAP and font checks must remain intact.

Self-hosting and vendoring UI assets are project requirements. GSAP **3.15.0** core
(including CSSPlugin) is bundled from `assets/vendor/gsap/gsap.js` through the existing
esbuild pipeline. No npm installation, JavaScript package manager, CDN import, or
runtime download is needed. Its custom Standard "No Charge" License is **not MIT**;
preserve the upstream notices and review licensing before changing product scope.
See the [vendor README](../assets/vendor/gsap/README.md) for provenance, registry
SHA-512 verification, local SHA-256 pins, license snapshot, and update procedure.
`mix audit` covers Hex packages, not vendored JavaScript; review GSAP advisories
separately when updating. ExUnit checks the pinned files and retained license notices.

Visual/interaction requirements, decorative DOM ownership, entrance lifecycle and the
browser verification checklist live in [UI_CONTRACT.md](UI_CONTRACT.md). Implementation
entry points are `assets/js/hooks/brand_reveal.js`, `workspace_entrance.js`,
`workspace_idle.js` and `stage_background.js`; registration is in `assets/js/app.js`.
No DrawSVG/SplitText plugin, `unsafe-eval` or remote script allowance is needed.

## Local settings and credentials

See [stage-designer setup](STAGE_DESIGNER.md) for optional non-secret settings.
`.env.example` is a readable, secret-free template; plain Mix does not load it.
Do not use plaintext environment variables or dotenv files to supply provider secrets.
Google OAuth client configuration is entered through hidden terminal prompts with
`bin/lovelace-sqlcipher mix lovelace.google.configure` and stored in the dedicated
keychain; there is no environment fallback. Gemini keys use Connections and the same
dedicated vault; `GEMINI_API_KEY` is ignored. Saving/removing a key never generates,
verifies provider access or changes startup opt-in. Tests/CI must use fake credentials.

Stage settings control an opt-in asynchronous startup generator after the first successful
ordinary unlock once per application startup (not page loads or subsequent relock/unlock),
a persisted 24-hour attempt cooldown, and an uncapped published-scene catalog. `Lovelace.StageDesigner` is the first production
Ash domain; provider work never runs in LiveView callbacks. `LOVELACE_WORKSPACE_IDLE_MINUTES`
controls the client-only screensaver (default three minutes). Scenes exposes the saved
catalog through bounded 20-image pages, persistent background selection, and confirmed potentially billable manual
requests without a manual daily cooldown. Automatic startup alone uses the persisted
24-hour cooldown; manual work refuses another unresolved reservation. A dedicated Gemini Oban queue handles one-shot
paid submissions, resumable retrieval by provider ID and deletion after successful local publication.
Ash retains all attempt metadata independently of job pruning, with bounded history pages. Scenes
has per-manual-request model/aspect/size controls (startup defaults are unchanged), explicit unknown
outcome acknowledgement and safe failure/cleanup details. See STAGE_DESIGNER.md for recovery and
Google storage policy. Scenes also saves
app-wide guided scene direction (subject, setting, light, palette), with an exact prompt
preview. Saving is local-only and never generates or changes startup opt-in. The saved
direction overrides the configured prompt for future manual/startup attempts; apply the
additive scene-direction migration first. Unsaved edits block manual generation until
saved/discarded, and confirmation refuses a concurrently changed saved prompt.
Do not inject real Google credentials into tests or CI. Test runtime forces real startup
generation off; focused provider tests inject fake keys/`Req.Test`. For maintenance,
set `LOVELACE_STAGE_ENABLED=false` to block new automatic generations; it does not cancel
already-authorized jobs while unlocked. Full vault Lock stops queues and provider work.
The workspace UI still runs without provider credentials when generation is disabled.
Three owner-approved bundled JPEGs replace the default SVG; an independent Ash singleton
chooses one once at application startup and preserves it across restarts. Apply the
additive `add_bundled_scene_default` migration before restarting an existing installation.
Static/live rendering only reads that preference; it does not reserve or generate scenes.
See `priv/static/images/scenes/README.md` for artwork provenance and checksum pins.

## Calendar

Optional read-only Google Calendar shares existing Google identities and Keychain credentials,
with explicit additional consent and independent account-scoped day/selection/cache state.
See [CALENDAR.md](CALENDAR.md) before changing its scopes, polling or retention. It adds no
runtime dependency or external service infrastructure. Calendar's Ash domain owns day
preparation, selection, reads and jobs; the browser supplies local midnight boundaries and
renders minimal cached event text without retaining events in socket assigns. The existing
minute sweep also discovers due Calendar work. Tests must inject fake Calendar providers,
never real Google responses or private calendar data.

## GitHub

Optional read-only GitHub.com personal accounts and organizations appear as reusable
workspace installations and separate open-pull-request readouts on Home. Membership
alone does not grant app access: both the signed-in user and installed app must have
access to each selected repository. No GitHub Enterprise, webhooks, writes, repository
checkout, comments, diffs, avatars or remote images are fetched.

### Register and connect the GitHub App

1. [Register a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)
   in GitHub settings. Enable **Device flow**, leave **Expire user authorization tokens**
   enabled, disable **Webhook → Active**, and allow installation on **Any account**.
   A callback URL, client secret and private key are not needed for this device flow.
   Do not enable “Request user authorization (OAuth) during installation.”
2. Set repository permissions to **Pull requests: Read-only** (Metadata is automatic).
   For check rollups, also grant **Checks: Read-only** and **Actions: Read-only**.
   No contents, write or account permissions are required. To omit check queries,
   set `config :lovelace, :github, checks: false`.
3. Set the App's public **Client ID** and URL slug in `.env`:
   `LOVELACE_GITHUB_CLIENT_ID` and `LOVELACE_GITHUB_APP_SLUG` (see `.env.example`).
   These identify the App; do not put a PAT, client secret or private key there.
   Restart and unlock normally so the additive `add_github_app_accounts` migration
   runs through the managed vault lifecycle. Do not run standalone migrations against
   real data. **This authorization change does not require rebuilding the native helper.**
   An older installation without the existing **LOVELACE GitHub** keychain service
   must follow the attended helper preparation in [GMAIL.md](GMAIL.md#1-local-preparation);
   never reset keys, replace initialized credentials or broaden keychain access.
4. Open **Connections → GitHub → Install / manage app access**. Install on your
   personal account and each desired organization, selecting at most **100 repositories
   per installation**. Organization administrators may need to approve installation.
5. Choose **Sign in with GitHub**. Enter the displayed code at
   `https://github.com/login/device`, authorize the App, and return to LOVELACE.
   Only enter a code you requested here. Pending approval expires within 15 minutes.
   Device codes and tokens never enter the browser; only the short user code is shown.
   Sign-in/cancel use ordinary owner-verified, CSRF-protected POSTs before instrumentation.
6. Add a discovered **Repository owner** to a workspace. One sign-in can discover
   several personal/organization installations; each owner can belong to several workspaces.
   After changing installation access, use **Refresh app installations**. If GitHub
   authorization expires or is revoked, sign in again as the same GitHub user;
   immutable owner identities and existing memberships survive reauthorization.

### Credentials, disconnecting and migration

The dedicated **LOVELACE GitHub** keychain service stores one expiring access/refresh
bundle per connection UUID. No client secret, private key or environment-token fallback.
The [device flow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app)
requests `offline_access`; [refresh](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)
is one-shot after a durable reservation. Unknown outcomes, interrupted refreshes and
failed rotated-token saves require sign-in again, not replay of the previous refresh token.
Global Lock stops ephemeral authorization, protected queues and provider work.

**Remove from workspace** detaches only that membership. **Remove owner everywhere**
fences its work and clears local memberships/cache, leaving the shared App sign-in.
**Disconnect account** fences all its owners, clears memberships/cache and deletes the
App credential bundle. Failed deletion remains visible with a retry action. Neither
action revokes authorization or uninstalls the App in GitHub; do that separately there.

Old PATs are not App credentials and are no longer accepted or used. Migration clears
old cached PRs, marks owners for reauthorization and preserves identities/memberships.
Original owner-UUID keychain items are retained until explicit **Remove owner everywhere**
or **Remove retained credential**. They remain reachable even after adoption by an App
connection or account disconnect. Reauthorization does not silently delete originals.

Errors distinguish missing public App configuration, denied/expired authorization,
rate limiting, provider verification, dedicated-keychain access and local unavailability.
Only allowlisted categories enter redirect URLs, never provider text, user codes or
tokens. Keychain failure does not mean GitHub rejected access. Do not rebuild the helper
or replace credentials indiscriminately.

### Read bounds and freshness

`Lovelace.GitHub` owns Ash connections, installation owners, workspace memberships and
owner-scoped jobs. Discovery is bounded to 500 accessible installations. PR reads use
only immutable repository IDs from the matching installation, rechecking installation
and repository access before publication. More than 100 selected repositories fails
honestly rather than silently omitting repositories. Select a smaller repository set.

Fixed-host private Mint transport has no redirects, automatic retries or payload
instrumentation: 20-second individual requests, 60-second discovery/PR-read deadline,
2 MiB responses. Repository queries run in batches of 20, fetching up to 50 open PRs
per repository, then retaining the newest 50 across the installation. Counts describe
accessible selected repositories, never all repositories in an organization.
Home shows repository, author, draft/review/check state and UTC update time with safe
GitHub links. Optional review/check detail failures are labeled as partial results.
Polling runs approximately every five minutes while unlocked/running (minute sweep);
persisted 15-minute rate-limit cooldowns cannot be bypassed by Refresh. Failures retain
the original observation timestamp; rows/counts expire after 24 hours. Sleep/offline
cannot deliver live updates. Tests use synthetic providers/keychains; the production
connector is disabled in test builds.

## Saved workspaces

`Lovelace.Workspaces` owns a SQLite `Workspace` resource with explicit read/create/rename
and starter-initialization actions. All require the server-supplied `%{role: :local_owner}`
capability, checked strictly (including missing IDs). This is **not authentication** and
must not be reused as a multi-user access design. The protected UI now mints it only after
owner-session verification. Workspace/account membership reuses Gmail connections without
mixing inboxes; credentials remain in Keychain and mail queries require account scoping.
See [GMAIL.md](GMAIL.md) for activation, native helper, retention and security decisions.

Managed schema migrations run through the password-unlocked vault lifecycle before
protected work starts; do not start an unkeyed Repo or run standalone `ecto.migrate`
against managed real data. Existing plaintext installations must first use the stopped
migration procedure above.

The first connected LiveView mount initializes **Personal** through a conflict-safe Ash
upsert with a fixed ID and no update fields. Reloads, reconnects, and directory refreshes
never reset its renamed name or timestamps. Disconnected HTTP rendering does not write
workspace records. Creation and rename use focused native-dialog modals with `AshPhoenix.Form`; names are trimmed, nonblank,
and bounded to 64 characters server-side. There are deliberately no delete/archive actions,
or projects. Account connection and read-only mail are implemented separately in `Lovelace.Mail`.

`StatusComponents.status_signal/1`, `assets/css/status.css` and the `StatusSignal` hook
share custom SVG activity/last-known-health states across Home, workspaces, mail, Calendar,
Gemini, Scenes and transport recovery. Routine labels use accessible focus/hover details;
attention/recovery copy stays visible. The hook only positions/dismisses details, including
hover-only Escape and embedded-link focus; CSS owns preference-aware motion. Provider work,
freshness hooks and action feedback remain separate.

`WorkspaceComponents.card/1` and `MailComponents` render directory and integration surfaces;
`HomeLive`/`HomeNavigation` own URL-driven patch navigation; `HomeMail` owns account-topic lifecycle. See
[UI_CONTRACT.md](UI_CONTRACT.md#home-workspace-and-integration-navigation) for control semantics,
management context and navigation behavior.

Workspace card health reads only Ash account/membership metadata, not message caches or
provider APIs. Known problems are grouped by workspace/account, and subscriptions follow
the current directory, workspace or global Connections context. A metadata update from
another account never requests the selected inbox. Home reads persisted per-account unread inbox conversation counts, independently timestamped
from cached pages. Polling obtains Gmail INBOX label `threadsUnread`; conversation flags on
a bounded page never establish an account-wide unread total. Apply the new additive count
migration before restarting the updated app; do not reset the database.

`MailComponents` renders balanced inbox rows and the dedicated plain-text reader. The
`MailReader` hook owns only ephemeral focus/scroll navigation memory, fenced by the opaque
result-list context and connection generation; it never persists bodies or queries. Native
message/metadata disclosures retain their `open` attributes across patches via LiveView JS.
`MailDate` and `MailFreshness` in `assets/js/hooks/mail_time.js` own small ignored text nodes,
format browser-local dates and age fetched-at observations without changing provider state.
Their timers/resume listeners are cleaned up on destruction. `test/js/mail_reader_test.mjs`
covers those lifecycle contracts; LiveView tests cover server search/page/context state.

`HomeComponents` supplies the local daily heading, account readout and freshness components.
`DailyOrientation` and `ObservationTime` hooks own only their ignored readout subtrees and
clean up timers/resume listeners. Default navigation is Home; the center navigation contains
Home, Workspaces, Connections, Scenes and Settings. The corner monogram is decorative only, and Escape/idle
preserve the current destination. Browser history/reload/deep links restore meaningful views,
including submitted mail searches/pages, Conversations and Connections providers. Only navigation
URLs, not drafts/dialogs/scenery focus, enter history. Direct
Home inbox reads use explicit owner-only account actions, not relaxed workspace membership
checks.

The live shell keeps `#workspace-content` as the working scroller (including navigation),
with a sibling `#workspace-controls` rail for stationary Lock and Escape guidance.
`WorkspaceEntrance` opens both inert gates through sticky LiveView JS; narrow/laptop
layouts reserve chrome bands so the rail cannot cover scrolling controls.

`Layouts.stage/1` is shared by `Layouts.app/1` and static owner unlock/setup screens.
Shared shell/focal-plane tokens live in `assets/css/app.css`; workspace card rules live
in `assets/css/workspaces.css`. The [UI contract](UI_CONTRACT.md) is authoritative for
visual behavior, gate/focus ownership and static/live differences. `mix test.js` discovers
all `test/js/*_test.mjs`; its fake-DOM coverage does not certify rendered browser behavior.

## Image validation dependency

`vix` 0.42.0 is pinned in `mix.lock` for JPEG validation, not image generation or UI code.
Its JPEG-specific loader uses `fail-on: :VIPS_FAIL_ON_WARNING`, sequential access, and
revalidation; extracting raw pixels forces lazy decoding. Before any native load, bounded
segment parsing limits the encoded file to 10 MiB and dimensions to 8192 per side / 16M
pixels. Decoded dimensions, band count, and pixel bytes are checked as well. The original
encoded bytes are stored without re-encoding, retaining metadata/provenance. Do not replace
this with header-only sniffing or a decoder that silently recovers damaged entropy data.

Vix's Elixir wrapper is MIT; libvips is LGPL-2.1-or-later and its bundled libraries have
additional upstream terms. Follow [Vix installation/provenance](https://github.com/akash-akya/vix/tree/v0.42.0)
and [libvips licensing](https://www.libvips.org/). Prebuilt macOS/Linux artifacts are provided
by Vix; building from source needs the upstream native toolchain/libvips. No GUI framework,
ImageMagick process, separate service, or runtime asset download was introduced. Native
compilation and packaged-release loading were verified with the existing local OTP29 /
Elixir1.20 runtime; hosted Linux CI remains unverified. Native decoding is not process
isolation; keep this dependency updated and retain the preflight limits.

See [STAGE_DESIGNER.md](STAGE_DESIGNER.md#documentation-review-output-formats-and-validation)
for Developer API MIME-schema findings and the PNG final-IDAT padding correction.

## Daily commands

```sh
bin/lovelace-sqlcipher mix setup
bin/lovelace-sqlcipher mix phx.server
bin/lovelace-sqlcipher mix format
bin/lovelace-sqlcipher mix check
bin/lovelace-sqlcipher mix audit
```

Use the wrapper for the Mix commands below as well. `mix check` selects `MIX_ENV=test` and executes:

1. `mix format --check-formatted`
2. `mix lint` (compile with warnings as errors, then `mix credo --strict`)
3. `mix security` (`mix sobelow --private --exit low`)
4. `mix ash.codegen --check` (migration/snapshot drift)
5. `mix test`
6. `mix test.js` (native Node test runner, no npm dependencies)
7. `mix assets.build`

`mix precommit` delegates to `mix check`. Neither fixes formatting nor updates the
lockfile. Run `mix format` explicitly before committing. Credo includes selected
AshCredo checks for authorization bypasses, missing policies/domain, raw repo calls,
sensitive attributes/accept lists, unknown actions, and wildcard mass assignment.
AshCredo is **unofficial and experimental**: examine findings, and don't weaken
policies or disable whole categories just to make a check green.

`mix lint` and direct `mix credo` select the test environment so compiled-introspection
checks can load `test/support` resources. If you override `MIX_ENV`, remember that
those modules are not compiled in dev. Compilation must precede standalone Credo runs.

Sobelow's `--private` disables update-check network requests; `--exit low` fails on
all reported confidence levels. `--skip` honors narrowly reviewed function annotations
in scenery storage/coordination and vault filesystem/migration helpers:
`Traversal.FileModule` cannot distinguish trusted local configuration plus exact
content-hash/UUID or vault-journal filenames from user-controlled paths. Annotations
cover bounded reads, private/exclusive file creation, validated cutover and explicitly
confirmed cleanup. Scenery tamper/retention tests and synthetic vault migration fault
checks exercise those boundaries. No whole-check, module, confidence-level, or
fingerprint exclusion is configured. Review annotations if
these functions change; never extend them to arbitrary uploads or user-selected paths.
The browser pipeline retains its explicit CSP; the image endpoint has a restrictive CSP
and `nosniff`. These are not an email sanitizer or a complete auth/security review.

`mix audit` runs `mix deps.audit` for known security advisories and `mix hex.audit`
for retired packages. It is intentionally separate from the local quality gate
because it accesses external registries/advisory repositories. CI runs both gates.
A clean audit is a point-in-time result, not a guarantee about all transitive code.

## Browser UI regressions

```sh
LOVELACE_STAGE_ENABLED=false mix test.ui
# If Chrome/Chromium is not in its usual location:
LOVELACE_BROWSER=/path/to/chrome LOVELACE_STAGE_ENABLED=false mix test.ui
```

This separate, explicit gate uses installed Chrome/Chromium and Node's built-in DevTools
WebSocket client: no npm packages, browser download or third-party test service. It fails
if a browser is unavailable; `mix check` and hosted CI do not automatically run it.
The alias rebuilds deployed assets (including compressed copies, avoiding stale gzip),
then `test/support/ui_browser.exs` starts a separate test-only app on an ephemeral loopback
port with a new disposable SQLite database, scenery directory and Chrome profile.
Migrations and synthetic owner/workspaces/account/image fixtures are local to that run.
Before publishing synthetic scenes, the runner also verifies the genuinely empty gallery
with the public bundled default artwork, including no-JS unlock, decoded image loading,
and the same default across static/live views, navigation, scenery wake and reload.
Gmail/vault responses are fake, Oban is manual, real transports/vault are refused by test
builds and generation is disabled. It does not reuse a user's server/profile/private data.

`test/browser/ui_contract.mjs` exercises the actual compiled assets and LiveView socket:
normal entrance/directional exit and gate; corner/Lock computed visibility and focusability;
static unlock with/without JavaScript; static/live image success/failure; native menus;
workspace/integration/Connections navigation; unsaved input, scroll and first-key/click wake;
reduced-motion changes; forced colors; desktop/narrow layouts; dedicated reader body size,
reading measure and long-token wrapping; native message/recipient disclosures and Refresh
preservation; reader Escape/wake and async browser-Back row-focus/scroll restoration;
real URL Back/Forward, copied conversation/search/page links and workspace reload; and page errors/off-origin
requests/CSP events across navigation. The real browser idle timer uses a shortened
**disposable DOM setting**; native Node tests retain the actual three-minute deadline.
Chrome is shut down and disposable data removed on completion. The runner has startup,
protocol, overall and shutdown deadlines; it is not a cross-browser or screen-reader suite.
See [UI_CONTRACT.md](UI_CONTRACT.md#verification-map) for coverage boundaries.

### UI themes

Authenticated `/settings` selects Charcoal, Earth, Sea Glass or Mist without changing scenery.
`assets/css/themes.css` is the sole home for raw UI palette values. Its `--theme-*` primitives
feed DaisyUI's existing `--color-*` API and shared semantic border/surface/glass/shadow tokens.
Keep component CSS on those semantic tokens; picker swatches use the same palette primitives.
All four themes are dark, and forced colors retains system-color overrides.

`assets/js/theme_boot.js` is a small synchronous, self-hosted esbuild entry loaded before CSS.
It restores only an allowlisted `lovelace:theme` value from browser-local storage; Sea Glass is
the fallback. The native-radio `ThemePicker` hook applies/persists selection and announces
failed storage without pretending it saved. Preferences do not enter the database, account
state or provider calls, and already-open tabs do not synchronize live.

`mix check` includes storage/failure/lifecycle regressions. `mix test.ui` exercises all four
themes across Settings, Home, Workspaces and mail, reload/history persistence, native keyboard
selection, preserved imagery, protected deep links and narrow/forced-color layouts.

## Test conventions

- Use `Lovelace.DataCase, async: false` for database/resource tests and the existing
  SQL sandbox helpers. `LOVELACE_TEST_DATABASE` optionally selects a disposable test
  database (create its parent directory first); it has no effect outside test config. Ash async execution is disabled in `config/test.exs`.
  Normal `mix test` uses unmanaged, synthetic test-only SQLite storage and sandbox
  setup, not the managed encrypted database/keychain. Never point
  `LOVELACE_TEST_DATABASE` at a real development/production database or migration backup.
- Keep ConnCase/LiveView tests synchronous because they also acquire the sandbox.
  Pure functions and isolated `Req.Test` cases may be asynchronous.
- Create records through Ash actions or `Ash.Generator` helpers. Use `Ash.Test` for
  validation/policy assertions; test denied operations as deliberately as allowed ones.
- Production domains go in `config :lovelace, :ash_domains`; don't register test-only
  resources as production domains just to appease a generator.
- Prefer Req's built-in test plug at the actual HTTP boundary. Explicitly pass the
  injected request/client options through integration code. Never let provider tests
  depend on Google, real OAuth tokens, or live mailboxes.
- Req.Test stubs are process-owned. Future job/process tests may need `Req.Test.allow/3`
  or explicit ownership setup; don't solve this by turning tests into network calls.
- Add Mox only when a behaviour boundary genuinely needs expectations independent
  of HTTP; do not mock Ash or SQLite instead of exercising them.
- Protect account separation with adversarial tests: reused provider IDs, cross-account
  links, late responses after switches, credentials, jobs, and PubSub subscriptions.

`test/support/ash_probe.ex` and `ash_domain.ex` are test-only infrastructure fixtures.
Their table is created transactionally within the sandbox and rolled back after each
test. They exercise Ash reads/creates, validation, and transaction rollback without
creating real application tables or migration snapshots.

Mix has built-in coverage reporting (`mix test --cover`); no ExCoveralls service or
coverage gate is configured yet. Set a meaningful threshold with the first product
resources rather than claiming coverage of unimplemented behavior.

## Ash development and migrations

`Lovelace.Repo` is an `AshSqlite.Repo` (still an Ecto repo). Writes use AshSqlite's
transaction support and a single SQLite connection. Keep transactions short and do
not hold them across network calls. There is no separate read replica/repo yet.

The declared minimum SQLite syntax version is 3.38.0, AshSqlite's baseline; managed
storage separately requires SQLCipher **4.20.0** linked through Exqlite. Raise the
declared syntax minimum intentionally before using newer features and verify CI compatibility.

When adding a domain resource:

1. Use an Ash resource/domain and explicit actions/accepted attributes/policies, not
   a parallel Ecto context implementation for the same behavior.
2. Register the domain in `config/config.exs`.
3. Generate migrations, review SQL, and commit **both migrations and resource snapshots**.
4. Test from an empty database as well as the current development database.

```sh
bin/lovelace-sqlcipher mix ash.codegen meaningful_change_name
# Managed migrations apply through vault unlock, not standalone ash.migrate.
# Check generated schema drift in the synthetic test environment:
MIX_ENV=test bin/lovelace-sqlcipher mix ash.codegen --check
```

Codegen drift is part of `mix check` now that `Lovelace.StageDesigner` owns a production
SQLite state resource. Its migration and snapshot must stay together. The singleton's
version-checked reservation commits before HTTP; SQLite does not support Ash's atomic
`expr_error`, so these three updates explicitly use the record path with a SQL version
filter (`require_atomic? false`, `atomic_upgrade? false`), not an unchecked read/write race.
Conventional `mix ecto.*` setup/reset workflows are not for managed real data. Do not generate
additional owner/auth resources without reviewing the existing single-owner password/session
implementation. Google identities use immutable `sub`, not case-insensitive email uniqueness.

The base Ash installer configured Spark formatting, current recommended compatibility
settings, dev/test policy diagnostics, signed pagination keysets, and dev protocol
recompilation support. Pagination keys are not authentication/token-encryption keys.
If compile-time Ash settings change after dependencies are compiled, rebuild affected
dependencies; do not disable compile-environment validation to hide a mismatch.

## Igniter and dependency guidance

Igniter is installed locally; no global generator installation is required for its
project tasks. Prefer a preview before applying a generator:

```sh
mix igniter.install package_name --dry-run
```

Review changes before accepting. In particular, installing `ash_authentication` with
its full installer may generate resources, strategies, routes, and migrations; those
were deliberately **not generated** in the historical foundation pass. The later owner-unlock
slice adds its own password strategy/resources without public signup. Protect `.tool-versions`,
loopback binds, design tokens, and existing project-specific guidance.

UsageRules configuration lives in `mix.exs`. It writes a linked index to
`DEPENDENCY_RULES.md`, leaving the hand-written root `AGENTS.md` compact. Dependency
sources remain in ignored `deps/`; run `mix deps.get` before following those links.

```sh
mix usage_rules.sync          # preview/confirm updates
mix usage_rules.sync --yes    # apply after review
mix usage_rules.search_docs "Ash.Test" -p ash
```

Refresh the guidance index when dependencies change. Not every dependency ships
usage rules (currently Req and AshSqlite don't); use their HexDocs directly:
[Req.Test](https://hexdocs.pm/req/Req.Test.html),
[AshSqlite](https://hexdocs.pm/ash_sqlite/getting-started-with-ash-sqlite.html).

## Tidewave safety

`Tidewave` is included **only in dev** and plugged under `if Mix.env() == :dev`.
Its MCP endpoint is <http://localhost:4000/tidewave/mcp> while the development server
runs. It can execute Elixir and SQL with the process's access to local data.

- Never set `allow_remote_access: true`, expose through a tunnel, or include it in
  production. Loopback binding remains mandatory.
- Clients require explicit MCP connection configuration; no agent/editor config or
  external service was silently installed by this bootstrap.
- Tidewave may inject a toolbar and relax CSP for development browser tooling
  (including `unsafe-eval`/frame restrictions). That is not a production CSP policy.
- Future real-mail development sessions must consider tools' access to message bodies,
  credentials, logs, and query results. Avoid sharing sensitive output with agents.

## CI and tooling scope

`.github/workflows/ci.yml` runs on pushes and pull requests with read-only repository
permissions. It reads Elixir/OTP from `.tool-versions`, caches dependencies/builds,
installs asset binaries, and runs `mix check` plus `mix audit` in the test environment.
It also installs Node LTS for the native hook tests; no npm install or external application
service is required. Local runs do not prove hosted runner/runtime availability;
verify the relevant GitHub run before claiming hosted CI passed.

Current tooling is defined by `mix.exs` and the CI workflow, not a wishlist of deferred
packages. Do not add infrastructure just because a package is conventional. New tooling
needs a concrete requirement from the current task, not an old plan.

## Private mail instrumentation

Repo ORM defaults set `log: false, telemetry_event: nil`: SQL telemetry contains both
bound parameters and returned rows. Do not use raw SQL or override those options for
mail. LiveView render payloads use bounded ephemeral `Mail.ViewData` references rather
than body-bearing socket assigns. Provider HTTP bypasses Req/Finch payload instrumentation.
Tests use fake providers/vaults; native Keychain operations and real Google connectors
are refused by test builds. Oban runs in manual mode in tests, without queues/plugins.

No external telemetry exporter is configured. The user explicitly accepted stock
Bandit's in-process HTTP conn metadata after verifying its official documentation;
request headers/query strings are not stripped before its initial event. Early password/
OAuth plugs avoid additional Phoenix instrumentation, not Bandit's prior emission.
Do not claim complete payload-free server telemetry, and do not attach payload loggers/
exporters without a new review. See `GMAIL.md` for the precise exception and trust boundary.
Escape/idle only changes scenery and continues work; use global Lock to revoke owner
sessions, stop protected work and close/lock storage. Development Tidewave remains a
separate trusted local code/SQL capability, not a sandboxed mail viewer.
