# LOVELACE — next-agent handoff

## 1. Purpose and authority

This document records the product interview, repository bootstrap, and subsequent Ash/tooling foundation.
The project name is **LOVELACE**, always uppercase, with a double cursive `l` monogram.
The internal rename is also complete: OTP app `:lovelace`, modules `Lovelace` and
`LovelaceWeb`, matching source/test paths, configuration/build/theme keys, and
`lovelace_*.db` database filenames. See section 12 for migration and verification notes.
Git hosting metadata and the external checkout folder are managed separately.
See `DEVELOPMENT.md` for tooling commands and testing conventions.
Treat **confirmed requirements** as product constraints. Architecture proposals and
open questions below are not additional user commitments. Read the actual code and
`mix.lock` before assuming a feature or dependency exists.

**Current status:** the blockers and regression gaps in
[the remediation handoff](REMEDIATION_HANDOFF.md) are implemented and verified;
section 21 records the remediation and its limits. Section 20 is the historical
review baseline, not an outstanding-defect list. Product integrations remain deferred.

LOVELACE's visual direction draws on the sterile, brutalist architecture in
*Blade Runner*. The long-term purpose is a personal productivity and innovation
homepage/dashboard, with custom integrations as needed. The first useful version is
narrower: **a project-oriented Gmail workspace**, not a general widget dashboard or a
full project-management suite.

## 2. Confirmed requirements

| Area | Decision from the user |
| --- | --- |
| Project name | LOVELACE, always uppercase; double cursive `l` monogram |
| Primary purpose | Orient the day and do focused work |
| First workflow | Project workbench, initially email-centered |
| Audience/access | One person, private access |
| Primary surface | Desktop browser |
| Runtime location | On the user's computer |
| Infrastructure preference | Minimize moving parts |
| Integration direction | Two-way workspace; Gmail first |
| Mail capabilities | Read/search, organize mail, draft replies, send from LOVELACE |
| Accounts | Multiple Gmail accounts; **do not mix inboxes** |
| Projects | LOVELACE owns project data; each project belongs to one Gmail account |
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

Bootstrapped using the installed Phoenix **1.8.9 generator**. The equivalent command
with the current application identifiers is:

```sh
mix phx.new . --app lovelace --module Lovelace --database sqlite3 --no-mailer --no-install --no-agents-md
```

The nonempty-directory confirmation was accepted to preserve `.tool-versions` and
`.git`. Dependencies were then fetched and locked. Resolved versions include Phoenix
1.8.16, LiveView 1.2.13, Ecto 3.14.2, and ecto_sqlite3 0.26.0; use `mix.lock` for
exact versions. There is no Swoosh mailer: Gmail sending will use the Gmail API.

Implemented:

- A conventional, non-umbrella Phoenix application (`:lovelace`, `Lovelace`, `LovelaceWeb`).
- `AshSqlite.Repo` over Ecto, transactional writes enabled, a single connection in all
  environments, SQLite configuration, stage-designer migration/snapshot, and seeds.
- Ash/AshPhoenix and authentication libraries; `Lovelace.StageDesigner` is the first
  production domain, with a persistent SQLite reservation/manifest resource and policies.
- Credo/AshCredo, Sobelow, mix_audit, Req/Req.Test, Igniter, UsageRules, and dev-only Tidewave.
- A `mix check` quality gate and `mix audit` online dependency gate; GitHub Actions configured.
- Explicit browser Content-Security-Policy; narrowly reviewed storage-path scan annotations
  are documented in `DEVELOPMENT.md` (no blanket exclusions).
- `/` is a full-viewport glass LiveView with an original local landscape. There is no
  top title. Click/keyboard focus sharpens the pane, blurs the scenery, and reveals a
  centered double cursive `l` monogram tracing onto the glass, followed by **LOVELACE**
  letters flipping up one at a time. Escape cancels/hides the brand and restores the scenery. No marketing, fake data, or product controls.
  Screen-reader instructions explicitly identify the unconnected work features. A
  configurable three-minute client-only inactivity timer returns focus to the scenery;
  intentional input wakes it, but mouse movement does not.
- Shared dark/amber design tokens, self-hosted Space Grotesk variable typography,
  custom favicon, keyboard focus and skip-link support. GSAP 3.15.0 is vendored locally
  with licensing/provenance/checksums; no npm install or runtime CDN is required.
- Tailwind/esbuild pipeline; generated daisyUI core component primitives retained.
- Generated error handling, telemetry, and development-only LiveDashboard.
- HTTP/LiveView shell and error tests plus test-only Ash persistence/validation/rollback,
  Req.Test, CSP, development-tool exclusion, and vendored asset integrity checks.
  See section 13 for the current verification record.
- Loopback-only dev **and production** listeners; development LiveView origin checks enabled.
- Opt-in, asynchronous Gemini startup generation with a persistent 24-hour attempt
  cooldown, no automatic retries, seven retained validated local PNG/JPEG images, and
  previous-image/SVG fallback.
  Open LiveViews update through app-wide PubSub. dotenvx keeps the API key/local settings
  encrypted and private; `.env.example` is credential-free. No gallery/editor UI exists;
  section 14 is the historical interview and section 15 records implementation.
- Git ignore rules for local credentials, databases/sidecars, dependencies, and builds.

**Not implemented:** account/project/mail schemas, OAuth, mailbox credential storage,
Gmail HTTP client, mailbox UI, message rendering, attachments, Gmail actions, synchronization,
PubSub domain notifications, durable jobs, login, desktop/startup packaging, or a product
backup/restore workflow. A basic Mix production release was validated during the rename.
The CI workflow is written but has not been executed on a hosted GitHub runner.
No job-runner dependency is installed. No Google credentials are needed to run the shell.

### File map

| Path | Role |
| --- | --- |
| `.tool-versions` | User-owned runtime selection; preserved unchanged |
| `mix.exs`, `mix.lock` | Dependencies and Mix aliases |
| `lib/lovelace/application.ex` | Supervision tree (Repo, PubSub, endpoint, generated utilities) |
| `lib/lovelace/repo.ex` | AshSqlite/Ecto repository with transactional writes |
| `lib/lovelace_web/live/home_live.ex` | Minimal glass workspace and wordmark |
| `lib/lovelace_web/router.ex` | Browser pipeline, root LiveView, dev dashboard |
| `lib/lovelace_web/components/` | Layouts and generated core UI components |
| `assets/css/app.css` | LOVELACE theme tokens and Tailwind setup (`lovelace` theme key) |
| `assets/js/app.js` | LiveSocket, hooks, amber navigation progress indicator |
| `assets/js/hooks/brand_reveal.js` | Local GSAP trace/letter reveal lifecycle |
| `assets/vendor/gsap/` | Pinned GSAP source, upstream metadata, license, provenance |
| `config/` | Dev/test/prod settings and runtime configuration |
| `priv/repo/`, `priv/resource_snapshots/` | Stage-designer migration/snapshot and seeds |
| `test/support/` | Connection and SQL sandbox helpers |
| `test/lovelace_web/live/home_live_test.exs` | HTTP/live shell, CSP, and test-environment MCP exclusion |
| `test/lovelace/` | Ash/SQLite and Req.Test foundation checks |
| `.credo.exs` | Credo plugin and explicit Ash security checks |
| `.github/workflows/ci.yml` | Quality/security/test/asset checks and online audits |
| `docs/DEVELOPMENT.md` | Dependency roles, commands, migrations, test conventions, tooling safety |
| `.env.example`, `docs/STAGE_DESIGNER.md` | Secret-free template, dotenvx workflow, generator/idle behavior |
| `lib/lovelace/stage_designer/` | Ash state/actions, settings, private Mint Gemini boundary, coordinated PNG/JPEG storage |
| `docs/STORAGE_COORDINATION.md` | Cross-BEAM private SQLite handle/raw-unlink protocol and crash reasoning |
| `assets/js/hooks/{workspace_idle,stage_background}.js` | Client idle lifecycle and local-image fallback |
| `test/js/workspace_idle_test.mjs` | Dependency-free Node hook tests, included in `mix check` |
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
Node/npm is not needed by the Mix-managed asset pipeline. Node LTS is now required
for the dependency-free JavaScript tests included in `mix check`.

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
and committed together. `Lovelace.StageDesigner` is registered with state and generic
action resources; it is app-wide scenery, not mailbox-owned data. Suggested future
mail/account domain namespaces (proposals, not existing modules):

- `Lovelace.Accounts`: future owner authentication plus distinct connected Google account
  identities and credential lifecycle. Do not make a linked mailbox a separate LOVELACE user.
- `Lovelace.Projects`: account-owned projects and explicit project/thread associations.
- `Lovelace.Mail`: account-scoped reads/actions and on-demand cache policies.
- `Lovelace.Integrations.Google`: OAuth and Gmail protocol/HTTP adapter, with a fake
  implementation or injected transport for tests.
- `Lovelace.Sync`: durable sync state, polling, reconciliation, status, and workers.
- `LovelaceWeb`: render state and handle user intent; do not perform long provider
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
- Gmail is authoritative for mail state. LOVELACE is authoritative for projects and
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
- Gmail authorization is distinct from access control to LOVELACE. Loopback binding
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
  floating frosted cards, or a wall of ornamental widgets. The user-approved glass
  direction below supersedes the original recommendation against glass.
- Keep controls, active account, unread/selected states, errors, and focus indicators clear.
- Never trade contrast or long-message readability for cinematic dimness.
- Motion should be functional, subtle, and respect reduced-motion preferences.

Initial tokens are in `assets/css/app.css`: background `#141412`, secondary surface
`#1b1b18`, border `#34342e`, text `#eeede5`, amber `#d6aa69`. They are a starting point,
not a fully approved visual system. No external font/CDN is required.

### Glass workspace standard (user-directed foundation)

- Fill the viewport edge to edge, not a centered dashboard card. No top-centered title
  or front-page marketing text. The finalized **LOVELACE** identity is an original double
  cursive `l` above the uppercase name,
  centered in the viewport and visible only when the glass is in focus.
- On focus the monogram traces over about 1.35 seconds, then eight letters flip up
  left-to-right with a short stagger. The brand also fades with the focal-plane change,
  without shifting layout or intercepting clicks. Duplicate focus/click events do not
  restart an active reveal; Escape pauses it and fresh focus replays it from the start. An always-available screen-reader heading names the workspace;
  the visual brand is decorative. The matching monogram is also the favicon.
- The interface is a nearly transparent window onto a distant, in-focus background.
  At rest, formal UI chrome is softly defocused (currently 1.4px); the scenery is sharp.
- Clicking the pane or reaching it by keyboard swaps the focal planes: chrome sharpens,
  scenery softens (currently 14px), and a restrained tint supports future working content.
  Repeated clicks keep the pane focused. Escape restores the distant view. The user
  subsequently requested a configurable inactivity timer: after three idle minutes the
  scenery returns. Click/keyboard/scroll/touch renew the timer; mouse movement does not.
  Click or keyboard input restores workspace focus without moving focus off controls.
- Focus switching uses LiveView client-side JS commands and CSS; brand choreography
  uses a GSAP hook on the decorative `phx-update="ignore"` subtree. No server events or
  persistence are involved in focus switching. The idle hook executes these same sticky
  client commands, preserves elapsed time across patches/hidden tabs, and tears down
  timers/listeners. Brand hook teardown removes listeners and reverts its GSAP context.
  Keyboard focus indicators and alerts never blur. Reduced motion shows the finished
  brand immediately, including if enabled mid-reveal; forced colors removes scenery/blur.
- Self-host UI assets and vendor third-party scripts/fonts with pinned versions, licenses,
  provenance, and checksums. No runtime CDN, font service, or remote-image dependency.
  GSAP's source is bundled by esbuild; it does not require a JavaScript package manager.
- `priv/static/images/distant-shore.svg` is original local fallback scenery, not a
  user-selected photograph. Optional Gemini output is fetched server-side under the
  explicit policy in `STAGE_DESIGNER.md`, validated, stored privately, and served locally.
  No browser external-image requests, animated backgrounds, or parallax.
- Extend this focal-plane model when adding real controls: keyboard focus must sharpen
  the working pane, the first click must still activate the intended control, and active
  content must remain readable. The current full-pane focus button is an empty-shell
  affordance; replace it rather than layering an invisible button over future controls.
- Shared implementation: `Layouts.app/1` and the `.workspace-*` CSS rules/tokens.
  The user approved the glass shell, scenery, and focus effect after viewing it.

### Typography standard

- The user selected **Space Grotesk** for an architectural, geometric character.
  Use the shared Tailwind `--font-sans` token throughout the UI; keep system fallbacks.
- The uppercase **LOVELACE** wordmark uses weight 300, 13px, and 0.45em letter gaps
  below the 104px hand-drawn SVG monogram (no cursive font or external asset needed).
  Regular UI text defaults to 400; the bundled upright variable font supports 300–700.
  Do not apply wordmark tracking or light weights to future long-form email content.
- Self-host the unmodified WOFF2 under `priv/static/fonts/space-grotesk/`, with the
  upstream SIL OFL 1.1 license and a provenance/checksum README beside it. No runtime
  Google Fonts/CDN requests; `font-display: swap` and a same-origin preload prevent
  invisible text and avoid unnecessary font-loading latency.
- The current face is upright only. Revisit italics and language coverage with real
  mail typography rather than silently claiming comprehensive script support.

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
  root response contained the original project title and unconfigured states. The temporary
  server was stopped afterward.
- Ignore rules checked for dev/test databases, `.env`, local secrets, and built assets.
- `.tool-versions` re-read and confirmed unchanged.

No visual browser review, production release execution, Gmail/API testing, or job-runner
validation was performed. Dependencies and build artifacts exist locally but are
ignored; the project files are uncommitted.

## 10. Ash and lean-tooling foundation update

The subsequent user request selected Ash for models/resources, domains, and
LOVELACE authentication, plus Credo, AshCredo, Tidewave, and Igniter. In the follow-up
scope questions the user chose **framework-only auth** and the **lean tooling baseline**.
No owner login, User/Token resources, auth routes, or Gmail integration were generated.

Installed and configured:

- Ash/AshSqlite/AshPhoenix; AshAuthentication and AshAuthenticationPhoenix libraries.
- Official base Ash installer settings: Spark formatting, recommended compatibility
  flags, redacted errors, signed pagination keysets, policy diagnostics in dev/test,
  and dev protocol recompilation support. Ash pagination/signing keys are not OAuth
  credential encryption keys; dev/test signing values are public development defaults.
- `Lovelace.Repo` uses AshSqlite, enables transactional writes, and declares a
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

## 11. Glass workspace, typography, and branding verification

The UI-only update removes the marketing and unconfigured section cards. It adds no
product functionality, dependencies, resources, remote backgrounds, or runtime changes.
The ongoing design contract is recorded in section 7.

- `mix check`: passed; **13 tests passed**, including local scenery delivery and
  accessible focus-control markup. Credo/AshCredo, Sobelow, and asset builds passed.
- `mix audit`: no vulnerabilities or retired packages found.
- Ad hoc headless Chrome checks through local DevTools: initial sharp scenery/soft
  wordmark, mouse focus, Escape reset, Tab focus, Enter/Space activation, reduced-motion
  transitions, forced-colors presentation, and viewport fit at 1440×1000 and 390×844
  passed. Resting/focused screenshots were inspected. No browser-test dependency added;
  these checks are not part of the permanent ExUnit/CI suite.
- Browser checks used the existing loopback dev server at `http://localhost:4000`.
  `127.0.0.1` HTTP works, but LiveView's enabled origin check expects `localhost`;
  security settings were not relaxed to accommodate the browser check.
- The user subsequently approved the glass design, then the LOVELACE branding.
  At that stage, cross-browser checks and a production release test remained open.
  Section 12 records the later release test. The temporary headless browser was stopped;
  the existing development server was left running.
  `.tool-versions` is unchanged.
- Subsequent typography update: `mix check` passed with **14 tests**, including local
  WOFF2 delivery and font preload markup; `mix audit` remained clean. Headless Chrome
  confirmed the bundled font loads at weights 300/400/500/700 and actually renders the
  wordmark using Space Grotesk Light (not a fallback). Focus/keyboard/accessibility and
  viewport checks were repeated successfully; the focused screenshot was inspected.
  The font asset and OFL license are vendored; no package dependency was added.
- LOVELACE branding implementation: `mix check` passed with **15 tests**; `mix audit` remained
  clean and digested assets were refreshed. Headless Chrome verified an invisible brand
  at rest, click/keyboard reveal, Escape hide, centered monogram with uppercase name
  beneath, updated document title, local Space Grotesk rendering, reduced-motion and
  forced-colors behavior, and desktop/mobile viewport fit. Resting/focused screenshots
  were inspected. The icon is an original SVG path, reused in the favicon; no package,
  cursive font, internal module, configuration key, or database rename was introduced.
  The user approved the branding and subsequently finalized LOVELACE as the project name.
  README, development guidance, agent instructions, and font provenance now use the
  finalized name. At that stage the change was limited to branding/documentation;
  section 12 records the subsequent internal application rename. After the documentation
  update, `mix check` passed again with **15 tests**, and `mix audit` remained clean.

## 12. Complete application rename

The user explicitly extended the finalized project name to all internal identifiers.

- OTP/Mix app `:lovelace`; application namespace `Lovelace`; web namespace `LovelaceWeb`.
  Source/test directories, configuration keys, supervision/PubSub names, Gettext backend,
  telemetry metrics, session cookie (`_lovelace_key`), theme/build profiles, colocated
  imports, live-reload paths, release examples, seeds, and documentation now agree.
- Removed obsolete application and colocated build output across dev/test/prod and
  regenerated static assets/digests. Dependencies and `.tool-versions` were not changed.
- Preserved local dev/test SQLite databases under `lovelace_dev.db`/`lovelace_test.db`
  using SQLite's backup API, verified integrity, and retained private originals and
  their sidecars under ignored `tmp/name-change-backups.DTpCBR/`. No mailbox, product
  schema, or production database migration was performed. See `DEVELOPMENT.md`.
- `mix check`: passed; **17 tests passed**, including application identity, matching
  Repo/metrics telemetry prefixes, renamed session cookie, and existing safety/UI tests.
  `mix audit`: no vulnerabilities or retired packages found.
- Production compile with warnings-as-errors, asset deployment, and `mix release`
  succeeded. `_build/prod/rel/lovelace/bin/lovelace` started with a temporary database,
  generated secrets, distribution disabled, and a `127.0.0.1` listener. HTTP and LiveView
  worked; a valid MCP initialization POST returned **404** and no Tidewave toolbar was
  injected. This was a packaged release test, not just `mix phx.server`.
- Headless Chrome on the packaged release verified the `lovelace` theme, local Space
  Grotesk rendering, hidden/resting brand, click/keyboard reveal, Escape reset, centered
  monogram/name, reduced-motion/forced-colors behavior, and desktop/mobile viewport fit.
- Development HTTP, renamed session/theme, watcher-built CSS/JS, and dev-only MCP
  initialization also passed on a temporary loopback server. Temporary release/dev
  servers and the browser were stopped; temporary production data/secrets were removed.
- A focused independent read-only review of application/configuration/asset wiring found
  no issues. A case-insensitive scan found no former-name references or filenames in
  nonignored project files. Cross-browser review and hosted CI remain unverified.
- Git hosting metadata, history, and the external checkout directory were not renamed.
  Neither checkout folder naming nor a hosting migration is required to run `:lovelace`.

## 13. Vendored GSAP brand reveal

The user selected GSAP and made self-hosting/vendoring an explicit project requirement.

- Vendored unmodified GSAP **3.15.0** core/CSSPlugin distribution and upstream package
  metadata under `assets/vendor/gsap/`, with a custom-license text snapshot and provenance
  README. The registry tarball's SHA-512 was verified before extraction; ExUnit pins
  source/metadata SHA-256 values and retained notices. No npm install, package-manager
  dependency, runtime CDN, external script request, or Mix dependency was added.
- GSAP is under its custom Standard "No Charge" License, not MIT. The vendored README
  links the authoritative terms and explains updates. `mix audit` only covers Hex;
  vendored JavaScript advisories must be reviewed separately on updates.
- `BrandReveal` runs only in the ignored decorative brand subtree. LiveView JS dispatches
  local focus/reset events; CSS still owns glass blur/opacity. The SVG uses native path
  measurement and dash animation (no DrawSVG), followed by eight HEEx-authored letter
  spans rotating up in a stagger (no SplitText). All visible branding remains uppercase.
- Repeated click/focus events do not restart an active sequence. Escape pauses the
  timeline while CSS fades out; fresh focus replays from the beginning. Reduced motion
  immediately shows the final brand, including when enabled mid-animation. Destruction
  removes native listeners and reverts the GSAP context/styles. No server work is added.
- `mix check`: passed with **20 tests**; `mix audit`: no Hex vulnerabilities or retired
  packages. Production warnings-as-errors compilation, minified assets, and packaged
  release assembly passed. No CSP relaxation or additional runtime listener was needed.
- Ad hoc headless Chrome checks on a temporary loopback-only packaged release verified
  normal-motion tracing, ordered 3D letter flips, repeated-click suppression, interruption
  and replay, reduced-motion changes, keyboard controls, forced colors, mobile fit,
  ignored-node preservation across a LiveView server update, and actual hook teardown.
  External requests were blocked/recorded: **zero attempted**. No production CSP
  violations or JavaScript exceptions occurred. Trace/flip/completed screenshots were
  inspected. These browser checks are not part of permanent CI.
- Temporary production/browser processes and data were removed; the pre-existing
  development server was left running. User visual approval, cross-browser testing,
  and hosted CI remain open. `.tool-versions` and `mix.lock` are unchanged.

## 14. Stage-designer interview and encrypted configuration (historical)

The user selected a **configuration-only** foundation, not implementation of a
Gemini client or designer UI. Confirmed future direction:

- Automatic curation of original cinematic brutalist architecture, distant landscapes,
  charcoal and restrained amber, quiet negative space; no people, text, or busy foregrounds.
- Gemini Developer API with a server-only Google AI Studio API key, favoring speed/cost.
  The initial template selects documented stable `gemini-nano-banana-2.1`, `16:9`, `1K`.
- Refresh on application-process startup only, with a 24-hour persistent cache/cooldown,
  one attempt, no automatic retries, and previous-image/original-SVG fallback.
- Both encrypted `.env` and private `.env.keys` stay local and ignored, with mode `0600`.
  Only the readable, credential-free `.env.example` belongs in Git. No live key supplied.

The installed dotenvx 2.38.2 CLI encrypted all template values into local `.env` and
created local decryption keys without a cloud service or OS-keychain change. Explicit
`dotenvx run` injection is documented; no Elixir dotenv dependency or implicit loader
was added. The stage variables are **not consumed by application code yet**. Changing
an enable flag does not implement generation; the existing homepage is unchanged.
See [STAGE_DESIGNER.md](STAGE_DESIGNER.md) for setup, the proposed configuration contract,
provider documentation/privacy caveats, and implementation prerequisites. Future
attempt reservations must survive failed requests/restarts to enforce cooldowns;
actual spending controls, output validation, local serving, and fake-provider tests
must exist before activation. Retention limits and an exact money budget remain open.

Verification: `mix check` passed with **20 tests**, clean Credo/AshCredo and Sobelow,
and successful assets; `mix audit` found no vulnerabilities or retired packages.
Local checks confirmed all 12 values decrypt to the example, the API key remains empty,
both private files are mode `0600` and ignored, the example is not ignored, and strict
injection refuses to execute without a decryption key. No values or keys were printed.
`git diff --check` passed. No browser check was needed for this configuration-only change.

No Google generation request, API-key validation, mailbox access, dependency change,
runtime-target change, or application-server restart was performed during this setup.

## 15. Startup generation and inactivity scenery mode

The user approved implementation and selected a **three-minute** configurable idle
period, intentional actions only (no mouse-movement wake), startup activation on their
next restart, and retention of the **last seven** generated images. This supersedes the
configuration-only status in section 14 and the original no-inactivity-timer contract.

Implemented:

- `Lovelace.StageDesigner` Ash domain, SQLite singleton state resource, explicit policies,
  generic startup/background/image actions, migration and resource snapshot. Internal
  service actor is required for writes; public reads expose only safe imagery/status.
  This is application-wide scenery, independent of mail/account identities.
- A temporary supervised Task makes at most one asynchronous startup attempt. The
  version-checked reservation commits before HTTP; timestamps survive failure/crash and
  enforce a minimum 24-hour cooldown. Repeated restarts and missing images do not bypass
  it. There is no timer, browser-triggered generation, durable job engine, or retry loop.
- Server-only Gemini REST boundary, header-only API key resolved at request time, fixed
  HTTPS host, redirects/retries off, overall deadline, bounded streaming JSON, refusal
  handling, and generic safe errors. No key/provider payload in logs, DB, or UI assigns.
- Static PNG validation (chunks/CRC, dimensions/pixels, bounded inflation and scanlines),
  10 MiB image / 16 MiB response caps, content-addressed private storage with atomic rename,
  seven-image manifest, and stale orphan/temp-file cleanup on startup checks after a
  five-minute concurrency grace period. Current/retained-image/SVG fallback remains local.
- Same-origin digest-only image endpoint, manifest membership/content-hash checks,
  `nosniff`, private cache headers, restrictive image CSP, and read-only LiveView PubSub
  updates. New image overlays appear only after load; failures leave the original SVG.
- Separate client-only `WorkspaceIdle` hook using the existing sticky focus/reset JS
  commands and brand events. Keyboard focus remains on controls; click/keyboard input
  wakes the workspace. Mouse movement does not renew/wake, patches do not reset elapsed
  activity, hidden-tab/sleep time counts, and teardown removes listeners/timers.
- Added `simple_sat` **0.1.4**, a pure-Elixir solver needed by the first Ash policies.
  SQLite does not implement `expr_error` for atomic optimistic locking; the three state
  updates explicitly use record-path SQL version filters instead. Stale writers fail.
- `mix check` now also checks Ash migration/snapshot drift and 32 native Node hook tests.
  CI installs Node LTS matching the existing moving runtime target; no npm install.
  `.tool-versions` is unchanged; `mix usage_rules.sync --yes` refreshed guidance.
- Sobelow uses `--skip` for five specifically annotated storage helpers only. An independent
  read-only review confirmed the traversal reports are false positives: roots are
  privileged local configuration and filenames are exact digest/UUID forms. Path, symlink,
  tamper, membership, and cleanup behavior is tested. No blanket category/module/low-level
  exclusion was added. See `DEVELOPMENT.md` before changing these invariants.

Verification:

- `mix check`: passed; **65 ExUnit tests + 32 Node tests**, clean Credo/AshCredo, reviewed
  scoped Sobelow annotations, schema-drift check, and assets. `mix audit`: clean.
- Development migration applied with generation explicitly disabled; no existing data
  was deleted. Production warnings-as-errors compile, assets deployment, and packaged
  release assembly passed. The release also migrated an empty temporary database.
- Headless Chrome against a temporary loopback packaged release with **fake PNG imagery**
  checked local overlay loading, focus/idle reset, mouse-movement exclusion, keyboard
  wake and preserved focus, Escape, reduced motion, failed-image SVG fallback, forced
  colors, and mobile fit. The browser check temporarily shortened the DOM timer only;
  deterministic Node tests exercise the actual three-minute deadline. No JavaScript/CSP
  errors or external requests were observed. Temporary processes/data were removed.
- Encrypted local nonsecret flags were updated for generation on the next restart,
  seven retained images, and a three-minute timer. The user's API-key entry was not
  inspected or changed. Private files remain ignored and mode `0600`.

The user's existing server was not restarted. **No real Gemini generation, API-key
validation, billing, or mailbox activity was performed.** The next dotenvx-backed app
restart may incur a charge. Real generated-image quality/account availability, hosted
CI, and cross-browser checks remain unverified. Gallery/editor/manual refresh controls
and an exact dollar budget remain out of scope. A persisted `generating` status after
an interrupted process represents an uncertain attempt; it is not an automatic retry.

## 16. Safe failure diagnostics and explicitly authorized diagnostic retry

The user reported the generic background-failure warning. The original implementation
threw away failure details; they could not be recovered from the persisted failed state.

- Added `StageDesigner.Diagnostics`: logs a safe stage/category, HTTP status, and actionable
  hints. The Gemini boundary returns allowlisted Google status/ErrorInfo reason codes,
  distinguishes connection and client-option failures, and never returns raw provider
  text, metadata, prompts, credentials, or exception messages for logging.
- Added an internal service-actor-only `retry_failed_startup` Ash action, explicitly
  separate from startup. It accepts only a failed prior attempt and takes a fresh
  version-checked reservation before making one request. It is never called automatically
  or from browser controls. User consent is required before any potentially billable use;
  ordinary startup cooldown/no-retry behavior is unchanged. Successful/running attempts
  are not eligible for this diagnostic action.
- A read-only authenticated model-metadata GET returned HTTP 200 with `generateContent`
  support. The public REST contract was independently reviewed; no unsupported field or
  model-ID defect was confirmed. Metadata access does not imply available generation quota.
- The user then explicitly authorized **one** diagnostic generation attempt. It returned
  **HTTP 429 / RESOURCE_EXHAUSTED**. No additional generation request or automatic retry
  followed. The reservation now reflects that deliberate attempt; the existing server,
  API-key entry, and scenery were not replaced/restarted. Check project API billing and
  model quota in AI Studio/Google Cloud before considering another explicit attempt.

Regression tests cover safe HTTP/error-code extraction, unknown/malicious provider text,
DNS/TLS and client-option failures, warning redaction, stage separation, operator-action
policies, and unchanged cooldowns. Tests still use only fake keys and `Req.Test`; the
single authorized real attempt was a diagnostic operation, not an automated test.

`mix check` passed with **74 ExUnit tests + 32 Node tests**, clean lint/security and
schema-drift checks, and successful assets. `mix audit` and `git diff --check` passed.
No UI behavior changed in this follow-up; browser checks were not repeated.

## 17. Image-format documentation review and JPEG compatibility

A later user-authorized single generation attempt reached image handling but failed
with `invalid_image`, rather than the earlier quota error. Its original MIME/payload
was discarded, so **JPEG mismatch is plausible, not proven**. The user requested a
documentation review and explicitly approved adding validated JPEG support. No further
real generation or authenticated provider request was made during this investigation.

Findings and corrections:

- Reviewed the Gemini Developer API REST reference and public v1beta discovery metadata.
  Existing `imageConfig` documents aspect ratio/size, not a reliable PNG output selector;
  the newer image-response-format schema explicitly supports JPEG. Imagen/Vertex fields
  must not be copied into the Developer API request. Existing supported request fields
  remain unchanged; MIME plus actual bytes now govern accepted PNG/JPEG output.
- Separate safe failure categories for unsupported formats, malformed image parts, bad
  base64, excessive size, MIME mismatch, and structural/decoder rejection. No raw response,
  prompt, image metadata, exception, or credential is logged to diagnose format failures.
- Added pinned **Vix 0.42.0** / libvips for JPEG-specific strict pixel decoding, with
  header/byte/dimension preflight before native loading, full lazy-image evaluation,
  warning-level failure, and decoded dimension/band/size checks. Baseline/progressive
  8-bit and grayscale JPEG are tested. Original encoded bytes/provenance are preserved,
  not transcoded, relabeled PNG, or authenticated as valid C2PA manifests.
- Local storage, digest routes, controller, background selection, UI allowlist, and mixed
  seven-image pruning/fallback now support canonical `.jpg` / `image/jpeg` alongside
  `.png` / `image/png`. Wrong extensions, MIME mismatches, and other types fail closed.
  Existing digest-only Ash manifests remain compatible; no schema change was necessary.
- PNG review reproduced rejection of unused final-IDAT bytes that PNG section 11.2.3
  tells decoders to ignore. Switched from undocumented `inflateInit/3` strict mode to
  the documented initializer; stream completion, exact scanlines, CRC/order, dimensions,
  and rejection of bytes after IEND remain. No inflate-boundary bug was reproduced.
- PNG synthetic C2PA `caBX` handling and image-sized input pass. PNG validation is
  structural, not a complete reconstructed-color/conformance proof; metadata preservation
  is not provenance authentication. Native JPEG decoding is not a process sandbox.

Verification: `mix check` passed with **86 ExUnit tests + 32 Node tests**, clean lint,
security and schema drift, and successful assets; `mix audit` passed. UsageRules guidance
was refreshed. Production warnings-as-errors compile, asset deployment, release assembly,
and native Vix loading passed on the existing OTP29/Elixir1.20 runtime. Headless Chrome
against a temporary loopback packaged release with a **locally encoded synthetic JPEG**
verified correct `.jpg`/`image/jpeg` serving and overlay, idle/focus/keyboard/reduced-motion,
failed-image SVG fallback, forced colors, and mobile fit, with no JS/CSP errors or external
requests. Temporary processes/data were removed; the user's existing server, credentials,
cooldown, and real images were untouched. Hosted Linux CI, cross-browser testing, and a
successful real Gemini image remain unverified. See `STAGE_DESIGNER.md` for source links
and `DEVELOPMENT.md` for native build/licensing notes. `.tool-versions` is unchanged.

## 18. First successful real generation and user display confirmation

After restarting with JPEG support, the user explicitly requested one generation.
The operator action generated, validated, stored, and activated a real background.
The user refreshed and confirmed that it displays. No extra automatic generation was
performed. The user's image, key, environment files, and private database remain ignored
and must not be committed.

The operator invocation ran in a separate BEAM process: its SQLite/files were shared,
but its local PubSub was not the running server's PubSub, hence the required refresh.
Generation inside the running server already broadcasts a LiveView image update; no
browser-visible regenerate control has been implemented. This distinction was explained
to the user. Broader visual-quality review, hosted CI, and cross-browser checks remain open.

## 19. Focused reviewer skills

Eight project-local Scopewright reviewers were created as portable Pi skills under
`.agents/skills/lovelace-*-reviewer/SKILL.md`: architecture, Ash/SQLite,
security/privacy, integration reliability, LiveView/UI, test reliability, account
isolation and final cross-file integration. See [reviewer routing and creation
prompts](REVIEWERS.md) for the names, individual definitions, scope boundaries and
invocation examples. Account isolation applies as account/Gmail work is introduced;
its existence does not imply Gmail is implemented.

Each skill embeds SCOPED criteria, evidence-based verdicts, exact failure markers,
untrusted-input defenses and strict read-only limits, including no command execution,
network access, delegation or private-data acquisition. Models are inherited, not
pinned. These are portable instructions, not a tool-permission sandbox or native
subagent adapters. Run `/reload` in an active Pi session, then invoke
`/skill:<reviewer-name>` with explicit target paths; the skill loads in the current
session rather than creating an isolated reviewer process.

Full-file readback and static checks passed for all eight outputs: YAML frontmatter,
names/descriptions, SCOPED section order, exact status markers, shared safety/reporting
requirements, local documentation links and whitespace. Runtime skill activation was
not exercised; reload/discovery and caller-controlled tool restrictions remain separate.

This was reviewer/tooling documentation work, not an application review. No
application/runtime/dependency/schema changes, private-data access, provider calls
or mailbox activity were needed. `mix check` and `mix audit` were not rerun for this
skills-only change; application verification records above remain historical.

## 20. Current-state review and next-agent remediation

All eight focused reviewers subsequently reviewed the current application tree.
The final cross-file assessment rejected acceptance for three confirmed HIGH issues:

1. Gemini's Req/Finch path emits credential-bearing request metadata into in-process
   telemetry. No external export or credential compromise was established.
2. Post-publication pruning uses a local stale manifest without cross-BEAM fencing,
   allowing an older publisher to remove newer imagery after a later publication.
3. Bundled Topbar lacks the required complete license/checksum asset records.

The test review also found nondiscriminating dimension-limit and tamper/membership
fixtures, missing stale publish/fail assertions, and missing identical-output retention
coverage. Add real transport-instrumentation and cleanup-interleaving regressions,
plus independent-connection reservation-commit evidence. Existing production image,
hash, membership and SQL-version guards are present; coverage gaps do not establish
that those guards currently fail. Ash/SQLite review found no source blockers, and
account isolation was N/A for the deferred Gmail implementation.

See [REMEDIATION_HANDOFF.md](REMEDIATION_HANDOFF.md) for F1–F3, G1–G8, secondary
advisories, safe reproduction evidence, acceptance criteria, implementation boundaries,
verification and re-review routing. **At that historical review point, no fixes
had been implemented; section 21 supersedes this status.**

Fresh review-time checks passed with generation explicitly disabled: `mix check`
(**86 ExUnit + 32 Node tests**, lint/security/schema drift/assets), `mix audit`
(no vulnerabilities or retired packages), and production warnings-as-errors compile.
Synthetic probes confirmed credential/prompt presence in Finch telemetry before any
connection and deletion of a newer temporary image by stale-list pruning. They used
no real credentials or images and did not start LOVELACE; temporary data was removed.
No application source, private configuration/data, runtime targets or dependencies
were changed. Browser, release-runtime/native loading, hosted CI and live-provider
behavior remain outside this fresh verification. Green gates are a baseline, not
approval of those then-outstanding issues or evidence of completed remediation.

## 21. Completed review remediation

Implemented F1–F3, G1–G8 and A1–A3 from `REMEDIATION_HANDOFF.md`:

- Gemini now uses a step-free Req request and private passive Mint adapter, avoiding
  Finch's credential-bearing instrumentation. Safe transport events contain only
  numeric timings/status and fixed categories. Real loopback TCP/TLS fake-boundary
  tests exercise streaming, errors/exceptions, byte/time limits, interim responses,
  safe diagnostics and connection closure. Test builds refuse the ordinary production
  connector, so missing fake wiring cannot issue a billable request.
- Storage/publication/cleanup share permanent per-root SQLite-sidecar exclusion via
  a private direct Exqlite handle. It cannot be revoked by the main Repo's timeout
  or connection death. Raw same-process unlink avoids queued post-crash deletion.
  Ash publication commits before separately locked cleanup rereads the authoritative
  manifest; old caller lists cannot delete newer images. Provider HTTP stays outside
  transactions/locks, and business versions are not cleanup counters. Keep
  `.stage-coordination.sqlite3` for the lifetime of a shared root; never rotate it
  while any process could use the root. See `STORAGE_COORDINATION.md` for assumptions,
  failure handling, orphan grace, native-lifetime evidence and operational rules.
- Verified Topbar 3.0.0 against its registry archive/immutable upstream commit,
  retained full MIT notice and provenance/checksum records, pinned integrity tests,
  and embedded the full notice in an esbuild-preserved legal comment. No executable
  Topbar behavior changed; GSAP/font records and tests remain intact.
- Discriminating valid oversized PNG/JPEG, wrong-hash replacement, unregistered-file,
  stale publish/fail, repeated-output retention and independent committed-reservation
  tests close the review gaps. Separate non-sandbox disposable SQLite pools and
  deterministic barriers cover stale cleanup, in-flight/identical digests, crash,
  rollback, main connection death/timeout and killed private lock owners. Mutation
  probes prove the image/hash/membership/distinctness assertions reject missing guards.
- Public `generating` reservations are `uncertain`, not asserted live tasks; persisted
  state, timestamps, cooldown and diagnostic eligibility are unchanged. Status/LiveView
  tests cover honest wording. Synthetic actual mount timings are documented in
  `STAGE_DESIGNER.md`, without an invented SLO or unnecessary optimization. Historical
  restart/generation chronology now agrees with section 18.
- Mint 1.11.0 and Exqlite 0.43.0 are explicit direct dependencies at their existing
  locked versions; dependency resolution left `mix.lock` unchanged. UsageRules refreshed.
  No business migration/snapshot or runtime-target changes were needed.

Fresh verification with generation disabled, key unset, and disposable databases:
`mix check` passed **132 ExUnit + 32 JavaScript tests**, lint/security/schema drift
and assets; `mix audit` found no vulnerabilities or retired Hex packages; production
warnings-as-errors compilation, minified assets and disposable release assembly passed.
The release migrated an empty database and reopened the current schema, fully validated
and stored a synthetic JPEG, published/pruned through Ash/storage, and served it through
the image action. Test-only loopback helpers were absent; HTTP/distribution stayed off.
Source-focused reviews cover transport security/reliability, storage/Ash concurrency,
image/vendor policy, regressions and uncertainty UI. Final cross-file current-state
source review and final telemetry-allowlist follow-up returned **[APPROVED]** with
no blockers/advisories; source review does not certify execution.

No private settings/credentials, real databases/imagery, mailbox or running server was
read, changed or restarted. No real provider or diagnostic generation was invoked.
Browser/cross-browser, hosted CI and live-provider behavior were not freshly verified.
Publication interleavings use two independent pools; a separate disposable release
smoke confirmed exclusion and subsequent acquisition across actual independent BEAMs.
Killing an in-progress native unlink is justified by the OTP dirty-NIF/resource contract,
not a fault injected into native code. Full completion evidence is in the remediation
handoff; earlier verification records remain historical.
