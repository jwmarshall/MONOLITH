# LOVELACE

A private, desktop-first workspace for deliberate work, with warm cinematic minimalism
and a nearly transparent glass interface.

The current product slice is an account-separated, read-only Gmail workspace with
optional Google Calendar agendas for today on Home and in workspaces.
Local owner unlock, reusable workspace/account connections, inbox/search/conversations,
calendar selection and background polling are implemented. **Google setup and a manual real-account
connection are required for a new installation. Automated tests use fakes, not a real
mailbox or calendar.** Projects, mailbox writes and calendar writes are outside current scope.

## Start here

- [Visual and interaction contract: shared stage, navigation and accessibility](docs/UI_CONTRACT.md)
- [Read-only Gmail: Google setup, local unlock, Keychain and privacy](docs/GMAIL.md)
- [Optional Google Calendar: consent, selection and today's agenda](docs/CALENDAR.md)
- [Development tooling and testing conventions](docs/DEVELOPMENT.md)
- [Focused reviewer skills, routing, and Scopewright creation prompts](docs/REVIEWERS.md)
- [Stage designer: setup, credentials, costs and safeguards](docs/STAGE_DESIGNER.md)
- [Repository working instructions](AGENTS.md)
- [Dependency-supplied agent guidance](DEPENDENCY_RULES.md) (requires fetched dependencies)

## Identity and naming

The project name is **LOVELACE**, always uppercase, with an original double-cursive-`l`
monogram and edge-to-edge glass interface. **Settings → Appearance** offers Charcoal, Earth,
Sea Glass (default), and Mist. Selection stays in this browser across reloads and changes
UI colors, not scenery. See the [visual/interaction contract](docs/UI_CONTRACT.md)
for branding, entrance, scenery/wake, navigation and accessibility behavior.
Scenery mode is visual only; use **Lock** to revoke the browser session.

GSAP, Space Grotesk, and the landscape are self-hosted. GSAP's pinned source is vendored
under `assets/vendor/gsap/` with license, provenance, and integrity checks—no npm install,
runtime CDN, font service, or remote image requests. Keep third-party UI assets local.

The implementation uses Mix/OTP app `:lovelace`, modules `Lovelace`/`LovelaceWeb`,
source directories `lib/lovelace/` and `lib/lovelace_web/`, the `lovelace` asset-build
profile, and `lovelace_*.db` database filenames. The generated release executable
is `bin/lovelace`. The Git hosting repository and checkout directory are managed
separately; no particular checkout folder name is required to run the application.

## Stack

- Elixir / Phoenix 1.8, LiveView 1.2, Bandit
- **Ash** resources, domains, actions, and policies
- **AshSqlite** over Ecto + SQLite (no separate database service)
- AshPhoenix; AshAuthentication password strategy for one local owner
- Tailwind CSS 4; generated daisyUI primitives with shared semantic theme tokens
- Req, ExUnit, LiveViewTest, and Ash's testing helpers
- Vix/libvips for bounded strict JPEG validation; original image bytes are kept locally

- Oban's bundled SQLite Lite engine for durable, account-scoped read polling
- macOS Security.framework helper for Gmail refresh tokens; private Mint provider HTTP

Owner unlock does not make LOVELACE safe to expose to a network. It remains personal
and loopback-only. See the Gmail guide's explicit local telemetry/privacy limitations.

## Local setup

Use the existing `.tool-versions` as the runtime source of truth:

```sh
asdf install              # if these runtimes are not already installed
elixir --version
node --version
mix setup
mix lovelace.keychain.build  # macOS + Apple Command Line Tools; required for real Gmail
mix lovelace.owner.setup    # hidden local-terminal password prompt; no web signup
mix phx.server
```

Open <http://localhost:4000>. Stop the server with Ctrl-C (twice if prompted).
For an interactive Elixir shell, use `iex -S mix phx.server` instead.

`mix setup` fetches dependencies, creates/migrates the development SQLite database,
runs the seed file, and installs/builds the Tailwind and esbuild binaries. Initial
setup requires network access and native build tools (for dependencies such as
bcrypt). No npm install, Docker, PostgreSQL, Redis, or Google credentials are required.
Assets use Mix-managed binaries. Node (the existing `.tool-versions` LTS target) is
required for the dependency-free JavaScript hook tests in `mix check`, not asset building.

The server listens on `127.0.0.1:4000`. Both development and production configuration
remain loopback-only. Unlock with the local owner password; use Lock to revoke the
browser session. IP aliases redirect to the canonical localhost origin. The development-only
LiveDashboard is at `/dev/dashboard`; Tidewave MCP is at `/tidewave/mcp`.
**Tidewave can execute code and SQL; never expose it through a tunnel or enable remote access.**

## Checks

```sh
mix check                 # format, compile, lint/security, schema drift, Elixir/JS tests, assets
mix audit                 # online: dependency advisories and retired Hex packages
mix test.ui               # separate browser gate; installed Chrome/Chromium required
```

`mix check` and its `mix precommit` alias run in the test environment and do not
rewrite formatting or unlock dependencies. Run `mix format` to apply formatting.
`mix lint` also selects the test environment so AshCredo can inspect compiled test
resources. The separate browser gate uses a disposable app/database/profile and fake
providers, not your running app or mailbox; set `LOVELACE_BROWSER` for a custom executable.
See the development guide for individual commands, coverage and conventions.

GitHub Actions runs checks and audits using the Elixir/OTP versions from
`.tool-versions` and Node LTS for hook tests. No Google credentials, browser installation, or network services
are required for tests. Dependency downloads and the online audit require network access.

## Local data and configuration

- Development: `lovelace_dev.db`; tests: `lovelace_test.db` (both gitignored).
  Existing local data was preserved during the rename; see the
  [namespace and local-data notes](docs/DEVELOPMENT.md#namespace-and-local-data).
- `Lovelace.Repo` uses `AshSqlite.Repo`; transactional writes are enabled, with one
  connection, a 15-second query timeout, and a 16-second SQLite busy timeout.
- Database-backed tests must remain synchronous. Ash async execution is disabled in tests.
- `mix ecto.reset` **destroys the current environment's database** and rebuilds it.
- `PORT=4001 mix phx.server` changes the HTTP port.
- [Stage-designer configuration](docs/STAGE_DESIGNER.md) uses the external dotenvx CLI:
  private encrypted `.env`, private `.env.keys`, and a public, secret-free `.env.example`.
  Start with `dotenvx run --strict -f .env -- mix phx.server` to inject the environment;
  plain Mix does not load dotenv files. Generation is opt-in, server-side, and asynchronous:
  once per opted-in eligible app startup or an explicitly confirmed request in Scenes,
  with a persistent 24-hour cooldown for automatic startup only, no automatic retries, an uncapped catalog of
  published local PNG/JPEG images, and previous-image/SVG fallback. Scenes lets you browse
  20 images per page and activate any saved image; the next successful generation becomes active.
  Confirmed manual requests have no daily cooldown, but cannot overlap an unconfirmed attempt. No API key is needed
  to view existing scenery. Enter the Gemini API key in Connections; it is stored in the macOS Keychain
  and is never returned to the browser. `GEMINI_API_KEY` is no longer read. See the guide
  for activation/costs and migration from the former environment setup.
- `.env*` (except `.env.example`), `secrets/`, generated `data/stage-designer/` content,
  databases, dependencies, and build outputs are ignored. Keep dotenvx private keys
  separately backed up; never commit credentials, real email, or token-containing fixtures.
- Generated dev/test signing secrets are public development defaults, not deployment
  credentials or keys suitable for encrypting OAuth tokens.

For a production-mode local release, `config/runtime.exs` requires
`DATABASE_PATH` and `SECRET_KEY_BASE`; Ash pagination signing derives a separate key
from the latter. Releases also require built assets and an explicit server start
(`PHX_SERVER=true`). Build the native Keychain helper on the target Mac before release
assembly. Desktop packaging and signed-installer/credential migration are not provided.

## Current foundation

`/` mounts the owner-protected `LovelaceWeb.HomeLive`: glass entrance, saved workspace
directory, workspace-specific account list and separate read-only Gmail views. There is
no fake mail. Optional `Lovelace.Calendar` agendas reuse Google connections with explicit
read-only consent and independent freshness. `Lovelace.Workspaces`, `Lovelace.Owner`,
`Lovelace.Calendar` and `Lovelace.Mail` own their Ash
resources/actions/policies and schema artifacts. `Lovelace.StageDesigner` retains the
independent startup scenery workflow. Read [the Gmail guide](docs/GMAIL.md) before enabling
Google access; it also documents recovery and verification limits. There is no standing
roadmap or handoff backlog. Future work starts with an explicit user request; verify current
implementation in code and run the relevant checks rather than relying on old completion logs.
