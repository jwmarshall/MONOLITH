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
- Persistent workspace cards, native create/rename modal dialogs and conflict-safe **Personal** starter;
  modals keep validation/drafts across patches, trap focus, pause visual idle, and restore
  trigger focus on save/cancel. Escape dismisses only the modal, not the working scenery plane;
  separate account tiles, Add integration and global Connections. Google connections are
  reusable across workspaces, without merging inboxes. Global Gmail cards are compact
  horizontal rows with responsive wrapping. **Add Gmail account** opens a native modal
  with required receiving-workspace selection, retained across unrelated patches; Cancel/Escape
  restores the Add button without starting OAuth. Local detach and confirmed global
  disconnect are distinct. Card health uses metadata, not provider calls or cached mail.
- Terminal-only owner setup and password unlock; account-scoped read-only Gmail inbox,
  search, plain-text conversations, bounded on-demand cache, Keychain credentials and
  durable Oban SQLite polling. Polls also read Gmail's INBOX `threadsUnread`; count errors
  retain prior observations and respect account cooldown/generation fences. Direct Home
  inbox reads use explicit owner-only actions, including unattached connections, without
  weakening workspace membership checks. Follow the Gmail guide for a new installation.
- Gmail Connections has an explicit per-account **Check Keychain**. It reads local
  credentials asynchronously and returns only safe categories plus an observation time;
  no Google call, permissions change, sync freshness/error update or credential output.
  Results are account/generation/view-fenced, with one pending check per view. Keychain
  sync failures now name the local boundary; a native help disclosure covers unlocked
  item denial and changed helper identity without claiming a confirmed ACL diagnosis.
  The native helper/source/build task are unchanged by this diagnostic addition.
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
- Global Connections separates app-wide **Google Gemini** scenery credentials from reusable
  Gmail accounts through a **Gemini / Gmail** subnav beside the title. Only the selected
  interface is mounted. Connections defaults to Gmail; Gemini credential POSTs return to
  Gemini. Keyboard switching retains navigation focus, Escape/idle preserves selection,
  and the contextual workspace return remains available. Re-selecting the current provider
  does not discard forms; leaving/reopening Connections defaults to Gmail.
  Keys are entered/replaced/removed through early authenticated, CSRF-protected
  ordinary POST forms and stored in the separate `LOVELACE Gemini` macOS Keychain service.
  `GEMINI_API_KEY` is ignored with no fallback/import; existing users must manually enter
  their key in Connections. Key presence/Keychain failures are explicit, not claimed Google
  verification. No key is returned to the browser or put in LiveView events/assigns.
  Saving/removing never contacts Google, changes generation opt-in or resets cooldowns.
  The rebuilt helper preserves Gmail's wire protocol and fences outdated helper binaries
  using Gemini-only operation names. User-confirmed local access/recovery is separate
  from automated tests; cross-version Keychain signing/migration remains unverified.
- App-wide opt-in Gemini startup scenery retains persisted cooldown/no automatic retries,
  validated local PNG/JPEG serving and retained-image/SVG fallback. Removing a key preserves
  imagery/reservations and cannot cancel an already-started provider request. The stage/storage
  guides own the detailed safety contracts.

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
- The user confirmed Gmail recovery after a locally authenticated, Gmail-service/login-
  keychain-scoped partition repair allowing only the current helper cdhash. Authorized
  metadata-only inspection established that visible app-list entries were current while
  Gmail partition ACLs still excluded that hash; Gemini's rule matched. No token values
  were inspected. Updating the visible application list alone was insufficient.
  Native `security set-generic-password-partition-list` prompts locally when insecure
  `-k` is omitted; never broaden the repair to Apple/all-application grants. The ad-hoc
  helper's signing/update stability is still unresolved: rebuilding changes its cdhash
  and can repeat this failure. See `GMAIL.md`; do not rebuild as an access repair.
- Real-provider recovery, native Keychain permissions/signing/migration, aesthetic approval,
  assistive technology, cross-browser behavior and hosted CI are not certified by local tests.
  Gmail cache is unencrypted; review the Gmail guide's stock-Bandit instrumentation exception.
  User reports of a working Google connection/background are not automated provider tests
  or standing permission for further billable attempts. No scenery dollar budget selected.

## Recorded verification and operational limits

Latest local checks, with generation disabled and disposable synthetic data:

- `mix check`: **349 ExUnit + 75 Node tests passed**, format, application warnings-as-errors,
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
  New coverage exercises native modal top-layer/focus/inertness, Escape-only cancellation,
  idle draft preservation, trigger focus on cancel/create; separate Gemini Keychain presence,
  an ordinary credential POST against a fake vault, blank return form, unverified/provider
  state wording, and Home after reload. Five synthetic Gmail accounts verify compact
  desktop row density, narrow/forced-color overflow safety and new-connection modal
  workspace choice and Cancel/Escape focus restoration. Provider navigation checks cover
  the same title row at desktop/narrow widths, keyboard focus/current-state semantics,
  mutually exclusive interfaces, scenery wake and Gemini POST return. LiveView tests cover
  metadata-patch form preservation, invalid provider requests, workspace return context
  and an in-flight Gmail disconnect completing safely while viewing Gemini. Credential
  diagnostics cover distinct safe results, no Google/credential writes or metadata changes,
  sanitization, owner-only authorization, one-at-a-time checks and late navigation/reconnect/
  disconnect fencing. Browser checks exercise local readability and synthetic item denial,
  truthful timestamps/unverified-Google wording and Keychain help at desktop/narrow widths
  in normal/forced colors, without credential disclosure or overflow.
  Reader checks cover native message/recipient disclosures, expansion choices through Refresh,
  escaped hostile bodies/headers, long-token wrapping, computed body size/reading measure
  and transparent reading background/inherited glass text treatment,
  reader Escape/wake and async Back restoration to the original row/scroll; delayed loading
  transparency, stable status space and normal/reduced/forced-color motion, including
  mid-load preference changes. No off-origin
  page requests, uncaught page exceptions or CSP violations observed. Detailed coverage/remaining manual checks are in the UI contract.
- `mix audit`: no vulnerabilities or retired Hex packages; `git diff --check` clean.
- The fresh disposable-database check emitted one transient SQLite connection-startup
  `database is locked` error log before ExUnit; all 349 tests passed. The startup
  contention was not investigated in this recovery pass.
- The native helper was not rebuilt or used against real Keychain items during the
  diagnostic addition; its existing executable identity is preserved. The synthetic
  framing regression compiles a temporary helper and sends invalid requests only.

The explicit browser gate is separate from `mix check`/hosted CI and requires installed
Chrome/Chromium. It shortens only a disposable DOM idle timer; Node tests retain the actual
three-minute deadline and hidden/sleep/patch cases. Release/native-runtime checks were not
freshly repeated. Hex audit does not cover all vendored-JS/native advisories.
No agent-triggered user-server restart, credential-value inspection or real-provider
operation was performed. User-authorized Keychain metadata inspection and an unsuccessful
native permission-write attempt (`-25293`, rules verified unchanged) preceded the user's
successful Terminal repair; these are manual recovery evidence, not automated tests.
The temporary native diagnostic/repair tools and disposable check database were removed.
Future verification commands and maintenance safeguards are in
`AGENTS.md` and the development guide; do not append historical completion logs here.
