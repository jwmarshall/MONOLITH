# Wallace — next-agent handoff

## 1. Purpose and authority

This document records the product interview, repository bootstrap, and subsequent Ash/tooling foundation.
See `DEVELOPMENT.md` for tooling commands and testing conventions.
Treat **confirmed requirements** as product constraints. Architecture proposals and
open questions below are not additional user commitments. Read the actual code and
`mix.lock` before assuming a feature or dependency exists.

Wallace is named for the Wallace Corporation from *Blade Runner*. The long-term
purpose is a personal productivity and innovation homepage/dashboard, with custom
integrations as needed. The first useful version is narrower: **a project-oriented
Gmail workspace**, not a general widget dashboard or a full project-management suite.

## 2. Confirmed requirements

| Area | Decision from the user |
| --- | --- |
| Primary purpose | Orient the day and do focused work |
| First workflow | Project workbench, initially email-centered |
| Audience/access | One person, private access |
| Primary surface | Desktop browser |
| Runtime location | On the user's computer |
| Infrastructure preference | Minimize moving parts |
| Integration direction | Two-way workspace; Gmail first |
| Mail capabilities | Read/search, organize mail, draft replies, send from Wallace |
| Accounts | Multiple Gmail accounts; **do not mix inboxes** |
| Projects | Wallace owns project data; each project belongs to one Gmail account |
| Thread membership | Explicit/manual linking, not automatic labels or search rules |
| Local email retention | On-demand cache, not a complete offline mirror |
| External freshness | Changes usually appear within a few minutes while running |
| Live behavior | External changes appear automatically; background progress is visible |
| Visual direction | Warm cinematic minimalism |

The user specifically suggested Elixir/Phoenix for background tasks and real-time UI.
The initial stack was Phoenix LiveView + Ecto/SQLite + Tailwind with durable jobs.
The user subsequently chose **Ash for resources/models, domains, and authentication**.
Ash/AshSqlite now form the domain/persistence foundation; job selection remains open.
The user explicitly chose framework-only authentication setup and the lean tooling
baseline: do not generate a login strategy, User/Token resources, or auth screens yet.

### Out of initial scope

No unified inbox, cross-account projects, public/multi-tenant product, mobile/native
client, full offline mailbox, general task/note/milestone system, AI agents, other
Google services, push-notification infrastructure, or automation platform. These are
not forbidden forever, but should not expand the first slice without discussion.

## 3. What actually exists

Generated using the installed Phoenix **1.8.9 generator** with:

```sh
mix phx.new . --app wallace --module Wallace --database sqlite3 --no-mailer --no-install --no-agents-md
```

The nonempty-directory confirmation was accepted to preserve `.tool-versions` and
`.git`. Dependencies were then fetched and locked. Resolved versions include Phoenix
1.8.16, LiveView 1.2.13, Ecto 3.14.2, and ecto_sqlite3 0.26.0; use `mix.lock` for
exact versions. There is no Swoosh mailer: Gmail sending will use the Gmail API.

Implemented:

- A conventional, non-umbrella Phoenix application (`:wallace`, `Wallace`, `WallaceWeb`).
- `AshSqlite.Repo` over Ecto, transactional writes enabled, a single connection in all
  environments, SQLite configuration, empty application migration directory and seeds.
- Ash/AshPhoenix and authentication libraries; no production domains/resources yet.
- Credo/AshCredo, Sobelow, mix_audit, Req/Req.Test, Igniter, UsageRules, and dev-only Tidewave.
- A `mix check` quality gate and `mix audit` online dependency gate; GitHub Actions configured.
- Explicit browser Content-Security-Policy; no security-scan findings suppressed.
- `/` is a LiveView with a Wallace-branded shell and explicitly unconfigured account,
  project, and sync sections. It has no domain actions or fake mailbox data.
- Shared dark/amber design tokens, custom favicon, keyboard focus and skip-link support.
- Tailwind/esbuild pipeline; generated daisyUI core component primitives retained.
- Generated error handling, telemetry, and development-only LiveDashboard.
- HTTP/LiveView shell and error tests plus test-only Ash persistence/validation/rollback,
  Req.Test, CSP, and development-tool exclusion checks. See section 10 for the current count.
- Loopback-only dev **and production** listeners; development LiveView origin checks enabled.
- Git ignore rules for local credentials, databases/sidecars, dependencies, and builds.

**Not implemented:** account/project/mail schemas, OAuth, credential storage, provider
HTTP client, mailbox UI, message rendering, attachments, Gmail actions, synchronization,
PubSub domain notifications, durable jobs, login, production packaging, or backups.
The CI workflow is written but has not been executed on a hosted GitHub runner.
No job-runner dependency is installed. No Google credentials are needed to run the shell.

### File map

| Path | Role |
| --- | --- |
| `.tool-versions` | User-owned runtime selection; preserved unchanged |
| `mix.exs`, `mix.lock` | Dependencies and Mix aliases |
| `lib/wallace/application.ex` | Supervision tree (Repo, PubSub, endpoint, generated utilities) |
| `lib/wallace/repo.ex` | AshSqlite/Ecto repository with transactional writes |
| `lib/wallace_web/live/home_live.ex` | Current workspace placeholder |
| `lib/wallace_web/router.ex` | Browser pipeline, root LiveView, dev dashboard |
| `lib/wallace_web/components/` | Layouts and generated core UI components |
| `assets/css/app.css` | Wallace theme tokens and Tailwind setup |
| `assets/js/app.js` | LiveSocket, hooks, amber navigation progress indicator |
| `config/` | Dev/test/prod settings and runtime configuration |
| `priv/repo/` | Future migrations and seeds (no domain tables yet) |
| `test/support/` | Connection and SQL sandbox helpers |
| `test/wallace_web/live/home_live_test.exs` | HTTP/live shell, CSP, and test-environment MCP exclusion |
| `test/wallace/` | Ash/SQLite and Req.Test foundation checks |
| `.credo.exs` | Credo plugin and explicit Ash security checks |
| `.github/workflows/ci.yml` | Quality/security/test/asset checks and online audits |
| `docs/DEVELOPMENT.md` | Dependency roles, commands, migrations, test conventions, tooling safety |
| `DEPENDENCY_RULES.md` | UsageRules-managed links into fetched dependency guidance |

## 4. Environment and verification

The user supplied `.tool-versions`:

```text
erlang 29.0.1
elixir 1.20.0
nodejs lts
```

During bootstrap these resolved to OTP 29.0.1, Elixir 1.20.0 (compiled with OTP 27),
and Node v24.22.2. `nodejs lts` is a moving alias, not an exact reproducibility pin;
it was deliberately not rewritten. `mix.exs` now requires Elixir `~> 1.20`.
Node/npm is not needed by the current Mix-managed asset pipeline.

See `README.md` for setup and commands. SQLite files are local and ignored.
Database-backed tests are synchronous; the test sandbox pool has one connection to
avoid fresh-database startup contention; Ash async execution is disabled during tests.
Do not introduce `async: true` for SQL tests. The write pool is also one connection in
other environments, with a 15-second timeout and 16-second busy timeout.

Initial dependency compilation emitted upstream warnings: LiveDashboard references
optional `Postgrex.Interval` despite using SQLite, and a dependency uses deprecated
Mix `xref` configuration. Runtime/binary downloads also emitted ignored HTTP-option
notices under OTP 29. Do not add PostgreSQL to silence an optional dependency warning.
A normal application compilation must still pass `--warnings-as-errors`.

Bootstrap verification results are recorded below after final checks. Tests use no
real Google account. A successful shell test does not validate OAuth, job processing,
or visual appearance in a browser.

## 5. Proposed implementation architecture

Use a modular monolith, not a collection of services. **Use Ash domains/resources,
actions, validations/changes, and policies for business behavior.** Do not implement
parallel hand-written Ecto contexts or duplicate action authorization in LiveViews.
AshSqlite still uses Ecto underneath; migrations and resource snapshots must be reviewed
and committed together. No production domains/resources exist yet (`ash_domains: []`).
Suggested future domain/integration namespaces (proposals, not existing modules):

- `Wallace.Accounts`: future owner authentication plus distinct connected Google account
  identities and credential lifecycle. Do not make a linked mailbox a separate Wallace user.
- `Wallace.Projects`: account-owned projects and explicit project/thread associations.
- `Wallace.Mail`: account-scoped reads/actions and on-demand cache policies.
- `Wallace.Integrations.Google`: OAuth and Gmail protocol/HTTP adapter, with a fake
  implementation or injected transport for tests.
- `Wallace.Sync`: durable sync state, polling, reconciliation, status, and workers.
- `WallaceWeb`: render state and handle user intent; do not perform long provider
  requests or embed sync logic inside LiveView callbacks.

These boundaries need not all become separate domains before the first feature.
Avoid empty abstraction layers or speculative integrations.

### Domain invariants

- An account identifier must travel through queries, caches, commands, jobs, and
  PubSub topics. A currently selected account in the browser is not an isolation check.
- Provider thread/message IDs must be namespaced by account; never key on provider ID alone.
- A project belongs to one account, and a linked thread must belong to that same account.
  Enforce this server-side and, where feasible, with database constraints.
- The selected account and sender identity must be unmistakable during composition.
- Switching accounts must not leak previous-account results through delayed responses,
  LiveView state, drafts, caches, subscriptions, or jobs.
- Gmail is authoritative for mail state. Wallace is authoritative for projects and
  manual project membership. Linking a thread should not silently modify Gmail labels.
- Search through Gmail initially; do not construct a full local mail index by accident.
  Fetch messages/attachments on demand. Cache limits, eviction, and retention need design.

### Sync and jobs

Start with periodic Gmail polling every few minutes and an explicit refresh action.
LiveView updates reflect state already discovered by the backend; they do not make
Google updates instantaneous. No Cloud Pub/Sub/webhook service is needed initially.

Polling should belong to the backend, not the browser session: closing a tab need not
stop it, but stopping the app or sleeping the computer does. Persist progress and
catch up on resume; do not promise execution while the machine is asleep.

**Job runner remains an open implementation decision.** Evaluate current Oban SQLite
support (including its Lite engine), version compatibility, migrations, licensing,
and scheduling/retry capabilities against the selected Ecto/SQLite versions. Prefer
a maintained SQLite-compatible durable queue over a custom queue; do not install
PostgreSQL/Redis merely to use a familiar worker setup.

Design for persisted per-account cursors, initial vs incremental sync, invalid/expired
history recovery, deduplication, rate limits, bounded retries, and understandable
failure/reconnect states. Keep database transactions short and do not hold a SQLite
write transaction over a network request. Test locking under concurrent UI/job writes.

Reads and idempotent updates can have bounded retries. **Email sending must not be
blindly retried after a timeout with an unknown outcome.** Persist user intent and
reconcile uncertain sends before offering a resend. Retry controls are action-specific.

## 6. Security prerequisites before real mail

The shell is not yet ready to store or render private email.

- Decide secure refresh-token storage: OS credential store vs application encryption
  with a separately managed key. Neither is implemented. Do not reuse the generated
  Phoenix development secret as a token encryption key.
- Review Google OAuth client type, loopback redirect behavior, state/CSRF protection,
  account identity binding, offline access, refresh-token handling, scopes, and revocation.
  Google consent/testing mode can affect refresh-token lifetime. Sensitive/restricted
  Gmail scopes can impose distribution/verification requirements; verify current policy
  for this personal application rather than assuming a public-app process is required.
- Gmail authorization is distinct from access control to Wallace. Loopback binding
  is not a complete security design. Retain CSRF/origin protections and review localhost
  request/session handling before connecting real accounts.
- Keep credentials and message bodies out of logs, exceptions, job payloads, telemetry,
  fixtures, screenshots, and commits. Add appropriate parameter filtering before OAuth.
- Treat messages as hostile HTML. Default to safe text or a deliberately sanitized,
  isolated renderer. No raw `Phoenix.HTML.raw/1` over provider content. Block scripts,
  unsafe URL schemes, and automatic tracking-image/remote-content loading.
- Draft/send actions must specify the account and require an explicit user action.
  Never send real email or mutate a real mailbox as part of automated tests.
- Design disconnect/revoke behavior, cache deletion, attachment handling, database
  permissions, and backup protection. SQLite is not encrypted merely because it is local.
- Public or LAN access requires a separate authentication, TLS, and deployment design.
  Current production settings intentionally bind only to `127.0.0.1`.

## 7. Visual contract

The user selected **warm cinematic minimalism**, grounded in sterile, brutalist,
minimalist dark architecture. Translate the reference, do not reproduce film branding.

- Near-black and charcoal planes, restrained warm amber, off-white text.
- Strong geometry, fine dividers, limited corner rounding, deliberate negative space.
- Strong typographic hierarchy; readable practical density inside mail/project views.
- Avoid neon cyberpunk, HUD decoration, excessive glow, animated backgrounds,
  gratuitous glass/gradients, or a wall of ornamental widgets.
- Keep controls, active account, unread/selected states, errors, and focus indicators clear.
- Never trade contrast or long-message readability for cinematic dimness.
- Motion should be functional, subtle, and respect reduced-motion preferences.

Initial tokens are in `assets/css/app.css`: background `#141412`, secondary surface
`#1b1b18`, border `#34342e`, text `#eeede5`, amber `#d6aa69`. They are a starting point,
not a fully approved visual system. No external font/CDN is required.

## 8. Recommended next work, in order

1. **Confirm remaining foundations.** Ash and the lean tooling baseline are installed.
   Run `mix check`/`mix audit`, inspect the shell in a browser, and validate SQLite-compatible
   jobs and OAuth/credential-storage choices. Owner-login strategy is deliberately
   deferred; get a decision before running auth generators. Record exact dependencies
   before promising sync reliability.
2. **Account connection.** Add account identity and protected credential handling,
   OAuth connection/reconnection/disconnection, and a minimal settings screen. Test
   isolation from the beginning, including two accounts with the same provider object ID.
3. **First read-only vertical slice.** Connect one account, show a paginated inbox,
   safely open a thread, create an account-owned project, and manually link/unlink it.
   This is a delivery increment, not a change to the two-way first-version goal.
4. **Sync.** Persist per-account sync state, poll independently of browser sessions,
   show progress/errors/last successful sync, and broadcast account-scoped UI updates.
   Verify restart/sleep catch-up and provider failure behavior.
5. **Multiple accounts.** Complete account switching and separate inbox/project
   navigation; prove delayed results and subscriptions cannot cross account boundaries.
6. **Mail writes.** Add read/unread, archive, labels, drafts, and explicit sending,
   with visible pending/error states and safe unknown-send reconciliation.
7. **Harden and polish.** Cache retention, disconnect cleanup, attachments policy,
   keyboard navigation, accessibility, packaging/startup, and local data backup guidance.

### Acceptance tests to carry forward

- Two accounts never share inbox results, projects, cached mail, subscriptions, or drafts.
- Cross-account project/thread linking is rejected on the server.
- Empty, loading, offline, expired-credential, rate-limited, failed, and retrying states
  are distinguishable; stale data is not presented as freshly synchronized.
- Project membership survives restart without depending on the message body cache.
- Periodic sync updates an open LiveView without a manual page reload.
- Pending jobs survive restart; app sleep/closure does not silently discard work.
- A send timeout does not produce an automatic duplicate message.
- Hostile HTML and tracking images cannot execute or load silently.
- Tests run offline against fakes; no credentials or real user mail are required.

### Still open (do not silently invent requirements)

Job engine and exact scheduling approach; OAuth client/scopes and secure key storage;
project/thread link cardinality; draft autosave and account-switch behavior; supported
sender aliases; attachment capabilities; precise cache retention; startup-on-login and
release packaging. Clarify these when they gate implementation, not by expanding scope.

## 9. Initial bootstrap verification record (historical)

Completed against the runtimes above:

- `mix setup`: passed; development database and assets created.
- `mix format --check-formatted`: passed after formatting.
- `mix compile --warnings-as-errors`: passed for the application.
- `mix test`: **6 passed**, with no database-lock error on the final run after
  reducing the test pool to one connection.
- `mix assets.build`: passed (Tailwind CSS and JavaScript bundles).
- Development HTTP smoke test on port 4017: `/`, `/favicon.svg`,
  `/assets/css/app.css`, and `/assets/js/app.js` all returned successfully; the
  root response contained the Wallace title and unconfigured states. The temporary
  server was stopped afterward.
- Ignore rules checked for dev/test databases, `.env`, local secrets, and built assets.
- `.tool-versions` re-read and confirmed unchanged.

No visual browser review, production release execution, Gmail/API testing, or job-runner
validation was performed. Dependencies and build artifacts exist locally but are
ignored; the project files are uncommitted.

## 10. Ash and lean-tooling foundation update

The subsequent user request selected Ash for models/resources, domains, and
Wallace authentication, plus Credo, AshCredo, Tidewave, and Igniter. In the follow-up
scope questions the user chose **framework-only auth** and the **lean tooling baseline**.
No owner login, User/Token resources, auth routes, or Gmail integration were generated.

Installed and configured:

- Ash/AshSqlite/AshPhoenix; AshAuthentication and AshAuthenticationPhoenix libraries.
- Official base Ash installer settings: Spark formatting, recommended compatibility
  flags, redacted errors, signed pagination keysets, policy diagnostics in dev/test,
  and dev protocol recompilation support. Ash pagination/signing keys are not OAuth
  credential encryption keys; dev/test signing values are public development defaults.
- `Wallace.Repo` now uses AshSqlite, enables transactional writes, and declares a
  conservative SQLite baseline of 3.38.0. One write connection in every environment;
  query timeout 15 seconds, busy timeout 16 seconds. Ash async tasks disabled in tests.
- Credo/AshCredo with explicit security-oriented checks; compile before introspection.
- Req + Req.Test, Sobelow (offline scan, no findings suppressed), mix_audit/Hex audits.
- Igniter and UsageRules. `DEPENDENCY_RULES.md` is a generated linked index; hand-written
  `AGENTS.md` stays compact. Not all packages ship usage rules; consult their HexDocs.
- Tidewave plug and dependency scoped strictly to dev. It can execute code and SQL;
  never enable remote access or tunnel the endpoint. No MCP client configuration was
  silently installed. Tidewave can relax CSP/inject development tooling in dev only.
- Browser CSP; a `mix check` gate (format/compile/Credo/Sobelow/tests/assets), `mix audit`
  online gate, and GitHub Actions configuration. Both `mix check` and `mix lint` select
  test so AshCredo can introspect the test-support modules.

Validation performed after the tooling update:

- `mix check`: passed; strict Credo/AshCredo and Sobelow report no findings;
  **11 tests passed**; assets build successfully.
- `mix audit`: no vulnerabilities found; no retired packages found.
- `MIX_ENV=prod mix compile --warnings-as-errors`: application compiled successfully.
- `MIX_ENV=prod mix assets.deploy`: assets minified and digest manifest generated.
- Dev HTTP shell and Tidewave MCP `initialize`: successful on a temporary server.
- Production-mode HTTP startup using temporary database/secrets: root page successful,
  valid MCP initialization POST to `/tidewave/mcp` returned **404**. Servers stopped and
  temporary production data removed. This was `mix phx.server`, not a packaged release.
- A read-only second-agent review of config, scopes, gates, CI, and tests found no
  blocking issues. Hosted GitHub Actions and visual browser behavior remain unverified.

Fresh dependency compilation still emits upstream Elixir-1.20 warnings (including
unused Logger requires in AshAuthenticationPhoenix, deprecated dependency `xref`
configuration, and optional LiveDashboard Postgrex references). The application
passes warnings-as-errors; no warnings or security findings were suppressed to do so.

Deferred deliberately: browser automation, Dialyzer/Dialyxir, dedicated property
suites, factory/mocking/coverage-service libraries, job engine, authentication strategy,
and all product resources. See `DEVELOPMENT.md` for commands, schema/snapshot workflow,
remaining caveats, and when to introduce those tools. Add a codegen-drift CI check
with the first real registered resource. `.tool-versions` remains unchanged.
