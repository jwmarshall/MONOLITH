# LOVELACE — current handoff

Keep this document to current status, unresolved work and latest verification. Replace
stale entries; product decisions belong in [AGENTS.md](../AGENTS.md), not a chronology.
Read actual code and `mix.lock` before assuming a feature/version exists.

## Guidance

- [UI_CONTRACT.md](UI_CONTRACT.md): visual, interaction and accessibility requirements/test map.
- [GMAIL.md](GMAIL.md): activation, owner unlock, OAuth/Keychain, polling, retention and privacy.
- [DEVELOPMENT.md](DEVELOPMENT.md): tooling, schema workflow, tests and dependencies.
- [STAGE_DESIGNER.md](STAGE_DESIGNER.md): scenery configuration, costs and safe operation.
- [STORAGE_COORDINATION.md](STORAGE_COORDINATION.md): scenery publication/cleanup protocol.
- [REVIEWERS.md](REVIEWERS.md): focused source-review routing.

## Current status

- Local Phoenix LiveView/Ash/AshSqlite application with registered Workspaces, Owner, Mail
  and StageDesigner domains. Listeners remain loopback-only; Tidewave is dev-only.
- Persistent workspace cards, create/rename and conflict-safe **Personal** starter;
  separate account tiles, Add integration and global Connections. Google connections are
  reusable across workspaces, without merging inboxes. Local detach and confirmed global
  disconnect are distinct. Card health uses metadata, not provider calls or cached mail.
- Terminal-only owner setup and password unlock; account-scoped read-only Gmail inbox,
  search, plain-text conversations, bounded on-demand cache, Keychain credentials and
  durable Oban SQLite polling. Follow the Gmail guide for a new installation.
- App-wide opt-in Gemini startup scenery with persisted cooldown/no automatic retries,
  validated local PNG/JPEG serving and retained-image/SVG fallback. The stage/storage
  guides own the detailed safety contracts; completed remediation is not open work.

## Open work and limits

- Reliable per-account unread totals need a provider/data design; badges remain deferred.
  Navigation is in-page: no URL/history/reload selection persistence or automatic cross-tab
  workspace-list synchronization. No workspace delete/archive actions.
- An interrupted first credential write or failed compensation can leave an unindexed
  Keychain item. No durable orphan reconciliation exists; manual guidance is in `GMAIL.md`.
  Exhaustive connected A→B→A delayed-provider/subscription and rotating-token reconnect/
  disconnect interleavings are not fully tested; no account leak was established.
- Projects, mailbox writes/drafts/sending, attachments, history-based reconciliation,
  password recovery, desktop/startup packaging and product backup/restore remain deferred.
  Clarify future project cardinality, draft/account-switch behavior, sender aliases,
  attachment policy and unknown-send reconciliation when they gate implementation.
- Real-provider recovery, native Keychain permissions/signing/migration, aesthetic approval,
  assistive technology, cross-browser behavior and hosted CI are not certified by local tests.
  Gmail cache is unencrypted; review the Gmail guide's stock-Bandit instrumentation exception.
  User reports of a working Google connection/background are not automated provider tests
  or standing permission for further billable attempts. No scenery dollar budget selected.

## Recorded verification and operational limits

Latest local checks, with generation disabled and disposable synthetic data:

- `mix check`: **280 ExUnit + 58 Node tests passed**, format, application warnings-as-errors,
  strict Credo/AshCredo, Sobelow, Ash schema drift and assets.
- `mix test.ui`: installed-Chrome regression passed against a separate temporary app/database/
  scenery/profile. Covers real CSS/LiveView entrance, gate/focus, corner/Lock, images, menus,
  navigation, first-input wake, unsaved input/scroll, reduced motion, forced colors and
  desktop/narrow layouts. No off-origin page requests, uncaught page exceptions or CSP
  violations observed. Detailed coverage/remaining manual checks are in the UI contract.
- `mix audit`: no vulnerabilities or retired Hex packages; `git diff --check` clean.

The explicit browser gate is separate from `mix check`/hosted CI and requires installed
Chrome/Chromium. It shortens only a disposable DOM idle timer; Node tests retain the actual
three-minute deadline and hidden/sleep/patch cases. Release/native-runtime checks were not
freshly repeated. Hex audit does not cover all vendored-JS/native advisories.
No user-server restart, private-data/credential inspection or real-provider operation was
performed for this pass. Future verification commands and maintenance safeguards are in
`AGENTS.md` and the development guide; do not append historical completion logs here.
