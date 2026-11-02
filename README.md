# LOVELACE

A private, desktop-first workspace for deliberate work, with warm cinematic minimalism
and a nearly transparent glass interface.

The first product slice is an account-separated, project-oriented Gmail workspace.
**This repository is currently a runnable foundation, not a working email client.**

## Start here

- [Agent handoff: requirements, architecture, guardrails, and next steps](docs/HANDOFF.md)
- [Next remediation: review blockers and regression gaps](docs/REMEDIATION_HANDOFF.md)
- [Development tooling and testing conventions](docs/DEVELOPMENT.md)
- [Focused reviewer skills, routing, and Scopewright creation prompts](docs/REVIEWERS.md)
- [Stage designer: encrypted configuration and agreed direction](docs/STAGE_DESIGNER.md)
- [Repository working instructions](AGENTS.md)
- [Dependency-supplied agent guidance](DEPENDENCY_RULES.md) (requires fetched dependencies)

## Identity and naming

The project name is **LOVELACE**, always uppercase. Its icon is an original double
cursive `l` monogram. The glass fills the viewport: at rest, the landscape is sharp
and the branding is hidden. Click or keyboard-focus the pane to soften the landscape
and reveal the centered monogram with **LOVELACE** beneath it; Escape restores the view.
The cursive `ll` traces onto the focused glass, followed by the LOVELACE letters flipping
up one at a time. Escape cancels the sequence; focusing again replays it. After three
minutes without intentional interaction, focus returns to the scenery; click or type to
resume. Mouse movement does not count. Reduced-motion mode shows the finished brand immediately.

GSAP, Space Grotesk, and the landscape are self-hosted. GSAP's pinned source is vendored
under `assets/vendor/gsap/` with license, provenance, and integrity checks—no npm install,
runtime CDN, font service, or remote image requests. Keep third-party UI assets local.

The implementation uses Mix/OTP app `:lovelace`, modules `Lovelace`/`LovelaceWeb`,
source directories `lib/lovelace/` and `lib/lovelace_web/`, the `lovelace` theme/build
profile, and `lovelace_*.db` database filenames. The generated release executable
is `bin/lovelace`. The Git hosting repository and checkout directory are managed
separately; no particular checkout folder name is required to run the application.

## Stack

- Elixir / Phoenix 1.8, LiveView 1.2, Bandit
- **Ash** resources, domains, actions, and policies
- **AshSqlite** over Ecto + SQLite (no separate database service)
- AshPhoenix; AshAuthentication + AshAuthenticationPhoenix installed for future auth
- Tailwind CSS 4; generated daisyUI primitives with LOVELACE's dark/amber tokens
- Req, ExUnit, LiveViewTest, and Ash's testing helpers
- Vix/libvips for bounded strict JPEG validation; original image bytes are kept locally

Authentication strategy/resources/screens, Gmail, and durable jobs are **not
implemented**. The job-runner package remains undecided. Adding auth dependencies
has not made this app authenticated or safe to expose to a network.

## Local setup

Use the existing `.tool-versions` as the runtime source of truth:

```sh
asdf install              # if these runtimes are not already installed
elixir --version
node --version
mix setup
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
remain loopback-only. There is no application login yet. The development-only
LiveDashboard is at `/dev/dashboard`; Tidewave MCP is at `/tidewave/mcp`.
**Tidewave can execute code and SQL; never expose it through a tunnel or enable remote access.**

## Checks

```sh
mix check                 # format, compile, lint/security, schema drift, Elixir/JS tests, assets
mix audit                 # online: dependency advisories and retired Hex packages
```

`mix check` and its `mix precommit` alias run in the test environment and do not
rewrite formatting or unlock dependencies. Run `mix format` to apply formatting.
`mix lint` also selects the test environment so AshCredo can inspect compiled test
resources. See the development guide for individual commands and conventions.

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
  once per eligible app startup with a persistent 24-hour attempt cooldown, no retries,
  seven retained local PNG/JPEG images, and previous-image/SVG fallback. No API key is needed when
  disabled. The API key never goes to the browser; see the guide for activation/costs.
- `.env*` (except `.env.example`), `secrets/`, generated `data/stage-designer/` content,
  databases, dependencies, and build outputs are ignored. Keep dotenvx private keys
  separately backed up; never commit credentials, real email, or token-containing fixtures.
- Generated dev/test signing secrets are public development defaults, not deployment
  credentials or keys suitable for encrypting OAuth tokens.

For a production-mode local release, `config/runtime.exs` requires
`DATABASE_PATH` and `SECRET_KEY_BASE`; Ash pagination signing derives a separate key
from the latter. Releases also require built assets and an explicit server start
(`PHX_SERVER=true`). Desktop packaging and secure credential storage remain future work.

## Current foundation

`/` mounts `LovelaceWeb.HomeLive`, with the full-viewport glass surface, focus-dependent
LOVELACE identity, and matching favicon. It has no marketing, fake mailbox data, or
product controls; screen-reader instructions identify the unconnected foundation.
`Lovelace.StageDesigner` is the first production Ash domain, with a SQLite singleton
for generation reservations and the retained-image manifest, explicit internal-write
policies, and committed migration/snapshot files. Gemini is the only implemented provider
boundary; Gmail and account/project resources remain unimplemented. Test-only Ash resources
still verify the foundation inside the SQL sandbox. Read the handoff before starting features.
