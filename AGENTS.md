# Working on LOVELACE

The project name is **LOVELACE**, always uppercase in prose and UI. Use `:lovelace`
for the OTP application, `Lovelace`/`LovelaceWeb` for modules, and `lovelace` in paths,
configuration keys, and database filenames.

Stack: Phoenix LiveView, Ash/AshSqlite over Ecto/SQLite, and Tailwind.

## Product direction

- A personal homepage for orienting the day and focused work, not a widget dashboard
  or full project-management suite. Deliver a Gmail-first workspace before expanding integrations.
- Home is the daily landing after unlock/reload: quiet per-account Gmail readouts, not
  a unified inbox. Workspaces lives behind navigation; Escape/idle wake preserves current work.
- Workspaces represent areas of life; **Personal** is the starter. One reusable Google
  connection can appear in several workspaces, and a workspace can contain several accounts.
  Keep account/integration tiles separate; workspace removal is not global disconnect.
- The current slice is read-only Gmail. Organizing mail, drafting and explicit sending
  are the longer-term two-way vision, not permission to add writes now. Projects are deferred;
  when introduced, each belongs to one account with explicit/manual thread membership.
- Gmail owns mail state; LOVELACE owns workspace/project data. Use bounded on-demand caching
  and Gmail search, not a full offline mirror or local mail index. Poll while the app runs;
  do not promise instant updates or execution while the computer is asleep/off.
- Show honest health, freshness and failure states. Unread signals must be per-account inbox
  conversation totals; defer numbers rather than infer totals from a partial page or fake zeroes.
- Discuss scope expansion first: no unified inbox, native/mobile client, general tasks/notes,
  AI agents or automation platform.

## Boundaries

- Personal, local-only desktop web app. Keep listeners on loopback. Network exposure
  or multi-user access needs an explicit security design, not just a bind change.
- Scope queries, writes, provider IDs, caches, jobs, and PubSub events by account;
  fence delayed results across account switches.
- Email and integration responses are untrusted content. Never render raw email HTML
  or fetch remote message content without a deliberate safety policy.
- Never commit/log tokens, credentials, real email, or private database files. Do not
  send real messages or modify a mailbox during automated tests.
- Sending is an explicit user action. Unknown send outcomes must not be blindly retried.
- Require explicit authorization before destructive database operations, file deletions
  or potentially billable provider calls.
- Preserve the user's `.tool-versions`; ask before changing runtime targets.
- Self-host UI assets. Vendor/pin third-party scripts and fonts locally with licenses,
  provenance, and checksums; no runtime CDN, font-service, or remote-image dependencies.

## Implementation

- Model business behavior with Ash resources, domains, actions, and policies, not parallel
  hand-written Ecto contexts. Register domains and commit migrations plus snapshots.
- AshAuthentication protects a single local owner; connected Gmail identities are separate.
  Owner setup is terminal-only. Keep HTTP/LiveView session guards and revocation intact.
- Tidewave is dev-only code/SQL execution. Never enable remote access or expose it via tunnels.
  No separate SPA, PostgreSQL, Redis, or unnecessary infrastructure.
- Keep business logic under `lib/lovelace/` and UI under `lib/lovelace_web/`.
  Keep provider HTTP/OAuth and long-running work out of LiveView callbacks.
- Oban 2.24's bundled SQLite Lite engine handles account-scoped polling.
  Keychain holds refresh tokens. See docs/GMAIL.md before changing grants/cache/jobs.
- No external telemetry exporter. Stock Bandit's in-process conn metadata is an explicit
  user-accepted local exception; never add payload logging/export without privacy review.
- Scenery is app-wide, not account-owned. Gemini generation is opt-in and potentially billable;
  preserve startup-only attempts, persisted 24-hour cooldown and no automatic retries.
  Gemini keys are managed in Connections and stored separately in macOS Keychain;
  no environment-key fallback or provider probe/generation on credential saves.
  Force `LOVELACE_STAGE_ENABLED=false` for maintenance; see docs/STAGE_DESIGNER.md.
- Clearly label placeholders; do not imply disconnected integrations are operational.
- SQLite sandbox/database tests must be synchronous. Use fake provider responses,
  not live Google calls. Keep `mix.lock` with dependency changes.

## Experience

- Warm cinematic minimalism: quiet brutalist geometry, charcoal/sea-glass, Space Grotesk,
  restrained motion and an edge-to-edge transparent glass stage shared by owner/workspace/mail views.
  Use quiet workspace cards; preserve the scenery/working-content focal-plane model.
  Escape/idle is visual, **not Lock**.
- Keyboard access, readable mail, contrast, reduced motion and forced colors outrank atmosphere.
  See docs/UI_CONTRACT.md for visual/interaction requirements and their verification map.

## Verification

Run `mix check` (format/compile/Credo/AshCredo/Sobelow/tests/assets) and `mix audit`
(online advisories/retired packages). For UI changes also run `mix test.ui` (installed
Chrome/Chromium; see docs/DEVELOPMENT.md). `mix lint` compiles in test for AshCredo introspection.
Keep durable decisions here and current status/open work in docs/HANDOFF.md; replace stale
status rather than appending a chronology. Refresh linked dependency guidance with
`mix usage_rules.sync` when dependencies change. Report unrun checks; never claim planned work exists.
