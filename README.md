# Wallace

A private, desktop-first workspace for deliberate work. Inspired by the Wallace
Corporation's sterile, brutalist architecture in *Blade Runner*, with warm cinematic
minimalism rather than decorative sci-fi UI.

The first product slice is an account-separated, project-oriented Gmail workspace.
**This repository is currently a runnable foundation, not a working email client.**

## Start here

- [Agent handoff: requirements, architecture, guardrails, and next steps](docs/HANDOFF.md)
- [Development tooling and testing conventions](docs/DEVELOPMENT.md)
- [Repository working instructions](AGENTS.md)
- [Dependency-supplied agent guidance](DEPENDENCY_RULES.md) (requires fetched dependencies)

## Stack

- Elixir / Phoenix 1.8, LiveView 1.2, Bandit
- **Ash** resources, domains, actions, and policies
- **AshSqlite** over Ecto + SQLite (no separate database service)
- AshPhoenix; AshAuthentication + AshAuthenticationPhoenix installed for future auth
- Tailwind CSS 4; generated daisyUI primitives with a custom Wallace theme
- Req, ExUnit, LiveViewTest, and Ash's testing helpers

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
Node is preserved in `.tool-versions`, but assets use Mix-managed binaries.

The server listens on `127.0.0.1:4000`. Both development and production configuration
remain loopback-only. There is no application login yet. The development-only
LiveDashboard is at `/dev/dashboard`; Tidewave MCP is at `/tidewave/mcp`.
**Tidewave can execute code and SQL; never expose it through a tunnel or enable remote access.**

## Checks

```sh
mix check                 # formatting, compile, Credo/AshCredo, Sobelow, tests, assets
mix audit                 # online: dependency advisories and retired Hex packages
```

`mix check` and its `mix precommit` alias run in the test environment and do not
rewrite formatting or unlock dependencies. Run `mix format` to apply formatting.
`mix lint` also selects the test environment so AshCredo can inspect compiled test
resources. See the development guide for individual commands and conventions.

GitHub Actions runs checks and audits using the Elixir/OTP versions from
`.tool-versions`. No Google credentials, browser installation, or network services
are required for tests. Dependency downloads and the online audit require network access.

## Local data and configuration

- Development: `wallace_dev.db`; tests: `wallace_test.db` (both gitignored).
- `Wallace.Repo` uses `AshSqlite.Repo`; transactional writes are enabled, with one
  connection, a 15-second query timeout, and a 16-second SQLite busy timeout.
- Database-backed tests must remain synchronous. Ash async execution is disabled in tests.
- `mix ecto.reset` **destroys the current environment's database** and rebuilds it.
- `PORT=4001 mix phx.server` changes the HTTP port.
- No Google environment variables or dotenv loading are wired up yet.
- `.env*`, `secrets/`, databases, dependencies, and build outputs are ignored.
  Do not commit credentials, real email, or token-containing fixtures.
- Generated dev/test signing secrets are public development defaults, not deployment
  credentials or keys suitable for encrypting OAuth tokens.

For a future production-mode local release, `config/runtime.exs` requires
`DATABASE_PATH` and `SECRET_KEY_BASE`; Ash pagination signing derives a separate key
from the latter. Releases also require built assets and an explicit server start
(`PHX_SERVER=true`). Packaging and secure credential storage remain future work.

## Current foundation

`/` mounts `WallaceWeb.HomeLive`, with a dark/amber shell and honest empty states.
No production domains or resources are registered yet (`ash_domains: []`). Test-only
Ash resources verify persistence and rollback inside the SQL sandbox; they do not
introduce product tables or migrations. Read the handoff before starting features.
