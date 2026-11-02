# Working on LOVELACE

The project name is **LOVELACE**, always uppercase in prose and UI. Use `:lovelace`
for the OTP application, `Lovelace`/`LovelaceWeb` for modules, and `lovelace` in paths,
configuration keys, and database filenames.

## Boundaries

- Personal, local-only desktop web app. Keep listeners on loopback. Network exposure
  or multi-user access needs an explicit security design, not just a bind change.
- Multiple Gmail accounts, never a unified inbox. Projects belong to exactly one
  account. Scope queries, writes, caches, jobs, and PubSub events by account.
- Email and integration responses are untrusted content. Never render raw email HTML
  or fetch remote message content without a deliberate safety policy.
- Never commit/log tokens, credentials, real email, or private database files. Do not
  send real messages or modify a mailbox during automated tests.
- Sending is an explicit user action. Unknown send outcomes must not be blindly retried.
- Preserve the user's `.tool-versions`; ask before changing runtime targets.
- Self-host UI assets. Vendor/pin third-party scripts and fonts locally with licenses,
  provenance, and checksums; no runtime CDN, font-service, or remote-image dependencies.

## Implementation

- Phoenix LiveView + Ash/AshSqlite over Ecto/SQLite; Tailwind with LOVELACE's dark/amber tokens.
  Model business behavior with Ash resources, domains, actions, and policies, not parallel
  hand-written Ecto contexts. Register domains and commit migrations plus snapshots.
- AshAuthentication support is installed, but strategies/resources/screens are deferred.
  LOVELACE owner authentication and connected Gmail identities are separate concerns.
- Tidewave is dev-only code/SQL execution. Never enable remote access or expose it via tunnels.
  No separate SPA, PostgreSQL, Redis, or unnecessary infrastructure.
- Keep business logic under `lib/lovelace/` and UI under `lib/lovelace_web/`.
  Keep provider HTTP/OAuth and long-running work out of LiveView callbacks.
- Gmail and jobs are unimplemented. Verify current package compatibility before
  choosing a SQLite job engine; do not assume Oban is already configured.
- Clearly label placeholders; do not imply disconnected integrations are operational.
- SQLite sandbox/database tests must be synchronous. Use fake provider responses,
  not live Google calls. Keep migrations and `mix.lock` with dependency/schema changes.

## Verification

Run `mix check` (format/compile/Credo/AshCredo/Sobelow/tests/assets) and `mix audit`
(online advisories/retired packages). `mix lint` compiles in test for AshCredo introspection.
Update the handoff when architecture/status changes and refresh linked dependency guidance
with `mix usage_rules.sync`. Report unrun checks; never claim planned work exists.
