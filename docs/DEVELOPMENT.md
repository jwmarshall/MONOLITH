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
| `ash_authentication`, `ash_authentication_phoenix` | Future LOVELACE authentication | Runtime; no strategy or resources configured |
| `req` | HTTP integration client; built-in `Req.Test` stubs/expectations | Runtime; test utilities used in tests |
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

Self-hosting and vendoring UI assets are project requirements. GSAP **3.15.0** core
(including CSSPlugin) is bundled from `assets/vendor/gsap/gsap.js` through the existing
esbuild pipeline. No npm installation, JavaScript package manager, CDN import, or
runtime download is needed. Its custom Standard "No Charge" License is **not MIT**;
preserve the upstream notices and review licensing before changing product scope.
See the [vendor README](../assets/vendor/gsap/README.md) for provenance, registry
SHA-512 verification, local SHA-256 pins, license snapshot, and update procedure.
`mix audit` covers Hex packages, not vendored JavaScript; review GSAP advisories
separately when updating. ExUnit checks the pinned files and retained license notices.

`assets/js/hooks/brand_reveal.js` owns only the decorative, ignored brand subtree.
LiveView client-side commands dispatch focus/reset events; CSS still owns glass blur
and opacity. The hook traces the SVG with native dash properties, then flips eight
HEEx-authored letters. No DrawSVG/SplitText plugin is used. It suppresses duplicate
focus/click replays, pauses on Escape, restarts on a fresh focus, responds to reduced
motion, and reverts its GSAP context/removes listeners when destroyed. Keep business
UI outside this `phx-update="ignore"` subtree. The always-present screen-reader heading
is separate; decorative letter-by-letter rendering is hidden from assistive technology.

Browser verification must include ordinary motion (not just reduced motion), stroke
progress, letter order, repeated focus, interruption/replay, preference changes, hook
teardown, LiveView updates, local-only requests, and the unchanged production CSP.
No `unsafe-eval` or remote script allowance is necessary for this integration.

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
4. `mix test`
5. `mix assets.build`

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
all reported confidence levels. No findings are suppressed in the initial baseline.
The browser pipeline has an explicit Content-Security-Policy. This is only one
layer of defense, not an email sanitizer or a complete auth/security review.

`mix audit` runs `mix deps.audit` for known security advisories and `mix hex.audit`
for retired packages. It is intentionally separate from the local quality gate
because it accesses external registries/advisory repositories. CI runs both gates.
A clean audit is a point-in-time result, not a guarantee about all transitive code.

## Test conventions

- Use `Lovelace.DataCase, async: false` for database/resource tests and the existing
  SQL sandbox helpers. Ash async execution is disabled in `config/test.exs`.
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

When the first domain resource is added:

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

Codegen drift is not part of `mix check` yet because no production domains/resources
exist. Add it with the first schema change. Conventional `mix ecto.*` tasks continue
to work against the same repo. Do not generate auth resources before choosing the
owner-login strategy and reviewing SQLite's email case-insensitive uniqueness behavior.

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
are deliberately **not generated** in this foundation pass. Protect `.tool-versions`,
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

## CI and intentionally deferred tools

`.github/workflows/ci.yml` runs on pushes and pull requests with read-only repository
permissions. It reads Elixir/OTP from `.tool-versions`, caches dependencies/builds,
installs asset binaries, and runs `mix check` plus `mix audit` in the test environment.
It does not require Node/npm or external application services. The hosted workflow
must still be verified on GitHub; local runs do not prove runner/runtime availability.

Deferred until justified:

- Browser automation (e.g. PhoenixTestPlaywright) for real JavaScript/auth/navigation.
- Dialyzer/Dialyxir for a maintained static type-analysis workflow and PLT caching.
- Dedicated property suites and mutation tests beyond Ash's existing generator support.
- Mox, ExMachina, ExCoveralls, extra frontend test runners, and documentation generators.
- Job-engine dependencies and Ash job extensions, pending SQLite compatibility/design.

Do not add infrastructure just because a package is conventional. Authentication
strategy, Gmail authorization, and durable jobs are separate future design steps.
