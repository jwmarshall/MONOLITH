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
- Home is the default after unlock/reload, with a browser-local date/greeting and quiet
  per-connection Gmail readouts: unread inbox conversation totals, independent count
  freshness/error state and workspace membership labels. The centered navigation opens
  Home/Workspaces/Connections, with Home leftmost; the corner monogram is decorative only.
  The centered logo exits with upward, left-to-right letter flips and opposite-end monogram
  erasure rather than a reversed entrance. All three views share content
  width/alignment with stable scrollbar gutters. Home copy is functional and minimal,
  numeric totals say **unread**, and global Connections has no redundant Home button.
  Escape/idle preserves current work. Inbox headers pair account identity with search
  on desktop and stack on narrow screens; search input/button touch at matching height
  and font size. Inbox Home buttons and redundant scope/reassurance copy are removed;
  shared navigation, actionable states and workspace All accounts remain.
- Persistent workspace cards, create/rename and conflict-safe **Personal** starter;
  separate account tiles, Add integration and global Connections. Google connections are
  reusable across workspaces, without merging inboxes. Local detach and confirmed global
  disconnect are distinct. Card health uses metadata, not provider calls or cached mail.
- Terminal-only owner setup and password unlock; account-scoped read-only Gmail inbox,
  search, plain-text conversations, bounded on-demand cache, Keychain credentials and
  durable Oban SQLite polling. Polls also read Gmail's INBOX `threadsUnread`; count errors
  retain prior observations and respect account cooldown/generation fences. Direct Home
  inbox reads use explicit owner-only actions, including unattached connections, without
  weakening workspace membership checks. Follow the Gmail guide for a new installation.
- Gmail inbox rows use balanced sender/date/subject/preview hierarchy and non-color-only
  unread markers. Conversations replace the inbox with a dedicated reader on the normal
  shared glass (no opaque fill, inherited stage text treatment; Canvas in forced colors),
  18px/17px Space Grotesk and a bounded 68ch measure. Earlier messages collapse, latest
  expands with an initial reply handoff; native metadata disclosures retain full escaped
  headers. Disclosure choices survive Refresh. Back restores search/page and the opened
  row's focus/scroll after async loading, with account/generation/result-context fencing.
  Dates format locally when parseable; fetch freshness ages independently with an exact
  timestamp disclosure. Loading now uses an unfilled, reserved sea-glass status line with
  a small indeterminate sweep (static under reduced motion/forced colors); warnings retain
  separate unfilled edges. No HTML, remote content, quote trimming or mailbox writes added.
- Apply additive migration `20261102195009_add_inbox_unread_totals.exs` before restarting
  the updated app. No private/development database migration or user-server restart was
  performed in this implementation pass.
- App-wide opt-in Gemini startup scenery with persisted cooldown/no automatic retries,
  validated local PNG/JPEG serving and retained-image/SVG fallback. The stage/storage
  guides own the detailed safety contracts; completed remediation is not open work.

## Open work and limits

- Unread counts use synthetic protocol/job/UI tests; real-provider count semantics and
  recovery still need manual confirmation. Unknown counts remain unavailable until polling.
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

- `mix check`: **311 ExUnit + 70 Node tests passed**, format, application warnings-as-errors,
  strict Credo/AshCredo, Sobelow, Ash schema drift and assets.
- `mix test.ui`: installed-Chrome regression passed against a separate temporary app/database/
  scenery/profile. Covers real CSS/LiveView entrance, left-to-right exit/opposite-end erasure,
  gate/focus, corner/Lock, images, menus,
  Home/unlock/reload and Home-first center navigation, decorative-only monogram, per-account unread readouts,
  shared/unattached accounts, consistent Home/Workspaces/Connections content bounds,
  redundant inbox Home removal and touching, matched-size search controls in split/stacked
  headers at desktop/narrow widths under normal and forced colors,
  mouse/keyboard Home, first-input wake, unsaved input/scroll,
  preserved inbox across Escape/idle, reduced motion, forced colors and desktop/narrow layouts.
  Reader checks cover native message/recipient disclosures, expansion choices through Refresh,
  escaped hostile bodies/headers, long-token wrapping, computed body size/reading measure
  and transparent reading background/inherited glass text treatment,
  reader Escape/wake and async Back restoration to the original row/scroll; delayed loading
  transparency, stable status space and normal/reduced/forced-color motion, including
  mid-load preference changes. No off-origin
  page requests, uncaught page exceptions or CSP violations observed. Detailed coverage/remaining manual checks are in the UI contract.
- `mix audit`: no vulnerabilities or retired Hex packages; `git diff --check` clean.

The explicit browser gate is separate from `mix check`/hosted CI and requires installed
Chrome/Chromium. It shortens only a disposable DOM idle timer; Node tests retain the actual
three-minute deadline and hidden/sleep/patch cases. Release/native-runtime checks were not
freshly repeated. Hex audit does not cover all vendored-JS/native advisories.
No user-server restart, private-data/credential inspection or real-provider operation was
performed for this pass. Future verification commands and maintenance safeguards are in
`AGENTS.md` and the development guide; do not append historical completion logs here.
