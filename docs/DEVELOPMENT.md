# LOVELACE development and testing

LOVELACE is the project name, always uppercase in prose and UI. The OTP app is
`:lovelace`, modules use `Lovelace`/`LovelaceWeb`, and the Tailwind/esbuild profile and
Tailwind theme key are `lovelace`. Sources live in `lib/lovelace/` and `lib/lovelace_web/`;
local databases use `lovelace_*.db`. See the [README](../README.md#identity-and-naming).

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
| `simple_sat` | Pure-Elixir SAT solver required by the first production Ash policies | Runtime |
| `ash_authentication`, `ash_authentication_phoenix` | Single local owner unlock | AshAuthentication password strategy; terminal-only setup |
| `req` | HTTP request/response contracts; built-in `Req.Test` stubs/expectations | Runtime; test utilities used in tests |
| `mint` | Private unpooled Gemini and Google transport, avoiding credential-bearing Finch telemetry | Runtime; pinned direct dependency |
| `oban` | Durable Gmail/Calendar polling and tracked Gemini scenery with bundled SQLite Lite engine | Runtime; 2.24.2, concurrency 1, cron/Lifeline/pruning |
| `exqlite` | Private SQLite coordination handle for cross-BEAM filesystem exclusion | Runtime; already used by AshSqlite, now an explicit direct dependency |
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

## Encrypted local environment

See [stage-designer setup](STAGE_DESIGNER.md) for dotenvx initialization, explicit
settings injection, permissions, backups, and privacy caveats. Gemini keys now use
Connections and macOS Keychain; `GEMINI_API_KEY` is ignored (no environment fallback).
Rebuild the native helper after updating to support the separate Gemini service.
Saving/removing a key never generates, verifies provider access or changes startup opt-in.
The external CLI (validated with 2.38.2) needs no npm/Mix application dependency.
Encrypted `.env` and plaintext private `.env.keys` remain ignored and owner-only;
`.env.example` is a readable, secret-free public template. Plain Mix does not load it.

Stage settings now control an opt-in asynchronous startup generator, persisted 24-hour
attempt cooldown, and an uncapped published-scene catalog. `Lovelace.StageDesigner` is the first production
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
generation off; focused provider tests inject fake keys/`Req.Test`. For maintenance commands,
force `LOVELACE_STAGE_ENABLED=false` to avoid an unintended application-startup request.
The workspace UI still runs without dotenvx or an API key when generation is disabled.
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

## Saved workspaces

`Lovelace.Workspaces` owns a SQLite `Workspace` resource with explicit read/create/rename
and starter-initialization actions. All require the server-supplied `%{role: :local_owner}`
capability, checked strictly (including missing IDs). This is **not authentication** and
must not be reused as a multi-user access design. The protected UI now mints it only after
owner-session verification. Workspace/account membership reuses Gmail connections without
mixing inboxes; credentials remain in Keychain and mail queries require account scoping.
See [GMAIL.md](GMAIL.md) for activation, native helper, retention and security decisions.

Apply the additive schema before using the updated homepage:

```sh
LOVELACE_STAGE_ENABLED=false mix ecto.migrate
```

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
Home, Workspaces, Connections and Scenes. The corner monogram is decorative only, and Escape/idle
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
mix setup
mix phx.server
mix format
mix check
mix audit
```

`mix check` selects `MIX_ENV=test` and executes:

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
in `StageDesigner.Storage` and `StageDesigner.Coordination` only: `Traversal.FileModule` cannot distinguish trusted local
configuration plus exact content-hash/UUID filenames from user-controlled paths. Narrowly
annotated helpers cover reads, directory/coordination-file creation, cleanup, bounded
file opening, and atomic writes. The invariants are documented at each function and exercised by digest,
symlink, tamper, unregistered-file, retention, and crash-cleanup tests. No whole-check,
module, confidence-level, or fingerprint exclusion is configured. Review annotations if
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

## Test conventions

- Use `Lovelace.DataCase, async: false` for database/resource tests and the existing
  SQL sandbox helpers. `LOVELACE_TEST_DATABASE` optionally selects a disposable test
  database (create its parent directory first); it has no effect outside test config. Ash async execution is disabled in `config/test.exs`.
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

The declared minimum SQLite version is 3.38.0, AshSqlite's baseline. The actual SQLite
library is supplied by Exqlite. Raise the declared minimum intentionally before using
newer SQLite syntax/features, and verify compatibility in CI.

When adding a domain resource:

1. Use an Ash resource/domain and explicit actions/accepted attributes/policies, not
   a parallel Ecto context implementation for the same behavior.
2. Register the domain in `config/config.exs`.
3. Generate migrations, review SQL, and commit **both migrations and resource snapshots**.
4. Test from an empty database as well as the current development database.

```sh
mix ash.codegen meaningful_change_name
mix ash.migrate
# Once resources/snapshots exist, check generated schema drift in CI:
mix ash.codegen --check
```

Codegen drift is part of `mix check` now that `Lovelace.StageDesigner` owns a production
SQLite state resource. Its migration and snapshot must stay together. The singleton's
version-checked reservation commits before HTTP; SQLite does not support Ash's atomic
`expr_error`, so these three updates explicitly use the record path with a SQL version
filter (`require_atomic? false`, `atomic_upgrade? false`), not an unchecked read/write race.
Conventional `mix ecto.*` tasks continue to work against the same repo. Do not generate
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
Escape/idle only changes scenery; use Lock to revoke the browser session. Development
Tidewave remains a separate trusted local code/SQL capability, not a sandboxed mail viewer.
