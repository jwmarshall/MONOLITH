# LOVELACE — visual and interaction contract

This is the current contract for all owner, workspace and mail surfaces. Keep visual and
interaction decisions here, durable product/safety rules in [AGENTS.md](../AGENTS.md),
and implementation status/evidence in [HANDOFF.md](HANDOFF.md). Later approved decisions
replace old requirements rather than accumulating a chronology.

## Direction and shared stage

- Warm cinematic minimalism inspired by quiet brutalist architecture, not film branding,
  neon cyberpunk, a marketing page or a decorative widget wall.
- One edge-to-edge, nearly transparent glass stage spans unlock/setup, workspace and mail
  views, including empty/error states. Do not turn the shell into a centered dashboard card.
- Charcoal, restrained sea-glass teal, pale neutral text, strong geometry, fine dividers,
  deliberate negative space and practical working density. Semantic warnings/errors remain
  distinct. **Sea-glass supersedes the original amber UI**; warm colors in scenery are not
  UI palette violations. Shared CSS tokens are the implementation source of truth.
- Self-host Space Grotesk with system fallbacks. Keep the name **LOVELACE** uppercase and
  the original double-cursive-`l` monogram. Wordmark tracking/light weight must not leak
  into long-form mail typography. Readability and contrast outrank cinematic dimness.
- Scripts/fonts/imagery are local, with applicable licenses, provenance and checksums for
  vendored assets. No runtime CDN, font service, remote browser imagery, animated scenery
  or parallax. Server-side opted-in Gemini output is validated and served locally;
  generation/cost/storage rules belong in [STAGE_DESIGNER.md](STAGE_DESIGNER.md).

## Focal planes and inactivity

- At rest, scenery is sharp; working content softly blurs and dims, and branding is hidden.
  Intentional focus sharpens content and softens scenery. Idle blur includes headings/mail
  (currently 3px); exact token/blur values are not immutable design requirements.
- Escape or configurable inactivity (default three minutes, range 1–60) restores scenery.
  Click, keyboard, scroll and touch renew activity; mouse movement neither renews nor wakes.
  Scroll/wheel/touchmove alone renew activity but do not wake an unfocused pane.
- Click/tap or non-Escape keyboard input wakes without consuming the first intended input,
  moving focus off its control or discarding current navigation, scroll or unsaved forms.
  No invisible full-pane activation control may cover working controls after entrance.
- The timer/focal-plane switch is client-only. Hidden-tab/sleep elapsed time counts;
  LiveView patches and background updates do not reset the activity timestamp. Hook teardown
  removes timers/listeners. No page load, wake or idle action starts background generation.
- This is **visual scenery mode, not authentication, Lock or a privacy guarantee**.
  Explicit **Lock** revokes the browser session; visual focus changes do not.

## Entrance, gate and persistent identity

- First activation traces the centered monogram, then flips the eight LOVELACE letters
  left-to-right. The completed logo holds briefly, then letters flip upward and out
  left-to-right while the monogram erases from the opposite end of its entrance trace.
  Working content becomes interactive only after exit. Current choreography uses a roughly
  1.35s trace, 250ms hold and 1.8× exit; equivalent restrained choreography may preserve
  the same contract.
- Duplicate activation does not restart an active sequence. Escape interrupts an unfinished
  entrance/exit; fresh activation replays it from the start at normal speed. Once completed,
  Escape/idle wake resumes immediately without replay. Full reload starts a fresh entrance.
- Server-owned working content is gated with `inert` until entrance completion. Remove the
  initial activation button permanently after handoff. Transfer initial focus to a meaningful
  heading without stealing focus from a control. Sticky client state survives LiveView patches.
- Keep GSAP ownership confined to the decorative `phx-update="ignore"` brand subtree;
  business controls/content stay outside it. Tear down listeners, media-query handlers and
  GSAP context when hooks are destroyed; patches must not duplicate/restart choreography.
- The corner monogram sits top-left, outside scrolling/gated working content. It is purely
  decorative: hidden from assistive technology, nonfocusable and never a navigation target.
  Lock sits top-right with matching responsive edge padding. Both appear only in an entered,
  focused live workspace. The corner stays hidden through the centered entrance/exit;
  both hide in landscape mode. Center navigation and Lock also lose keyboard access there.
- Static unlock/terminal-setup pages share the stage and current validated local imagery,
  show the corner immediately and stay focused. They have no idle timer, entrance gate or
  LiveView dependency. Keep a persistent accessible “Unlock LOVELACE” heading even when
  visible title/wordmark copy is omitted.

## Home, workspace and integration navigation

- Home is the default after unlock/reload. Escape/idle wake preserves the current view,
  scroll and forms; it never navigates Home. Explicit OAuth workspace returns retain context.
- A centered navigation bar contains **Home**, **Workspaces**, and **Connections**, in that
  order. These are native buttons for the existing in-page navigation; current destinations
  are identified with `aria-current`. Home is a visible text control, never the decorative
  corner monogram. Lock stays separate. Global Connections has no additional Home/back
  button; use the center navigation. Gmail inboxes likewise have no redundant Home
  button. A contextual workspace-return button remains when Connections was opened
  from a workspace.
- Home opens with a restrained greeting and date in the browser's local time, updated
  across midnight/resume. Home, Workspaces and Connections use the same content width and
  alignment from the shared directory container; Home has no narrower inner cap. Reserve
  symmetric scrollbar gutters so scrolling pages do not shift the content plane. Keep copy
  functional and minimal: no “Your day” eyebrow, slogans or explanatory footer. Numeric
  account totals are labeled simply **unread**. No clock, message previews, total across
  accounts or future widgets.
- Gmail readouts use quiet horizontal rows: one per non-disconnected connection, including
  connections with no workspace membership. Each shows identity, workspace names, actual
  unread inbox conversation total and independently timestamped count freshness/health.
  Clicking a row opens only that account's read-only inbox without attaching it anywhere.
- Unknown counts are not zero. Failed updates retain known counts as stale; elapsed time
  marks observations stale after three minutes, independent of unrelated mail-page success.
  Home rendering reads persisted metadata, never provider calls or cached message content.
  Empty/loading/error/reconnect states remain explicit, with recovery through Connections.

- Workspaces represent areas of life. **Quiet sea-glass cards supersede the earlier
  typographic/no-card directory**. Use generous native button surfaces and separate native
  management disclosures for rename; opening and management are siblings, never nested controls.
- Workspace detail prioritizes separate integration/account tiles, never an aggregate inbox.
  **Add integration** is a focused panel for reusable connections or connecting Google;
  Gmail is the only implemented integration, not a speculative provider catalog.
- **Remove from workspace** detaches locally; global **Connections** owns health, reconnect
  and confirmed **Disconnect everywhere**. Global connect/reconnect forms explicitly select
  the receiving workspace, preserving identity and membership context.
- Card health is last-known metadata, not a fresh provider check. Entering/rendering cards
  or management does not fetch mail or provider health. Account updates cannot refresh a
  different selected inbox. Never infer unread totals from a bounded cached page: Home
  counts come from Gmail's INBOX label `threadsUnread`, scoped to each account.
- Inbox headers split account identification and search into two desktop columns, stacked
  on narrow screens. Search input and submit button touch, with matching height and font
  size. Keep an accessible search name without a visible account-scope explanation or
  generic reassurance copy. Retain actionable health/freshness/error states and workspace
  **All accounts** navigation in the mail toolbar.
- Inbox rows balance sender/date, a prominent subject and one muted preview line. Unread
  uses a visible marker plus stronger text, with an accessible unread label; not color alone.
  Parseable message dates use browser-local compact labels, with full dates available;
  unparseable dates remain escaped provider text rather than invented timestamps.
- Opening a conversation replaces the results with a dedicated reader on the normal
  shared glass, with no separate opaque fill. Inherit the stage's text treatment; retain
  the accessible Canvas background in forced colors. Do not add a new dashboard shell.
  Use comfortable Space Grotesk body type (currently 18px desktop / 17px narrow), relaxed
  line spacing and a bounded reading measure (currently 68ch). Long tokens wrap; narrow
  screens reduce padding rather than shrinking body type below that starting point.
- Show one conversation heading. Earlier messages use native expandable sender/date
  summaries; the latest message starts expanded and the reader begins at that reply.
  Differing subjects remain visible within their messages. Full sender/recipient/raw-date
  metadata has its own disclosure. Preserve quoted history/signatures as escaped text;
  no automatic trimming, HTML rendering, remote content, attachments or mailbox writes.
  Disclosure choices survive ordinary refreshes. Escape/idle preserves reader state.
- Back to results retains search/page and restores the opened row's focus and scroll
  position after the async list returns. Client navigation memory is ephemeral, bounded
  to one result context and reset on account/connection-generation/search/page changes;
  never persist bodies or queries in browser storage. Routine fetch freshness is compact
  and ages locally, with an exact timestamp disclosure. Loading/errors/stale-copy warnings
  stay explicit and announced; cached content must not imply a new successful fetch.
- Mail loading uses a transparent, reserved status line on the shared glass: sea-glass
  text and a small decorative indeterminate sweep, never a filled warning box or invented
  percentage. Loading completion alone must not shift retained content. Reduced motion
  (including changes mid-load) and forced colors use a static marker. Keep polite textual
  announcements and separate unfilled warning edges for actionable errors/stale states.
- Navigation currently stays in-page at `/`, without URL/history or reload selection
  persistence. Do not imply reload persistence or cross-tab directory synchronization exists.
- Loading, empty, stale, offline, expired-credential, rate-limited and failed states must
  remain truthful and distinguishable. Account context stays explicit in mail views;
  disconnected integrations must not appear operational. Detailed Gmail boundaries live
  in [GMAIL.md](GMAIL.md).

## Images, accessibility and preferences

- Reveal a generated image only after it successfully loads. Failed loads leave the original
  local SVG fallback, not a broken-image replacement. Accept only the validated same-origin
  PNG/JPEG digest routes; no provider-hosted/arbitrary URL substitution. Static and live
  stages share image-load behavior; a read-only background lookup never starts generation.
- Preserve native keyboard operation, meaningful headings, labels, validation associations,
  announced errors/status and visible focus. Decorative branding is hidden from assistive
  technology; a persistent screen-reader heading supplies the page name separately.
- Reduced motion skips entrance/exit choreography, including preference changes mid-animation,
  while still completing the gate/focus handoff once. Forced colors removes scenery/blur/
  dimming but preserves the entered/focused visibility rules for corner monogram and Lock.
- Keep layouts usable at desktop and narrow widths; long messages remain readable. Source
  assertions and fake-DOM tests do not establish rendered contrast, focus or accessibility.

## Verification map

Use native Node and synchronous LiveView/ConnTest suites plus the explicit
`LOVELACE_STAGE_ENABLED=false mix test.ui` Chrome/Chromium regression gate. No real mailbox,
Keychain operation or billable provider calls are needed. See [DEVELOPMENT.md](DEVELOPMENT.md)
for commands and [HANDOFF.md](HANDOFF.md#recorded-verification-and-operational-limits) for
actual executed evidence.

- `test/js/brand_reveal_test.mjs`: choreography, interruption/replay, reduced motion and teardown.
- `test/js/workspace_entrance_test.mjs`: gate completion, focus handoff, patch continuity and teardown.
- `test/js/ui_browser_runner_test.mjs`: early normal/signal Chrome exit must fail promptly,
  not hang on an already-fired event or report success; no real browser/app is launched.
- `test/js/workspace_idle_test.mjs`: elapsed-time/activity/wake rules, patches/hidden tabs,
  timer cleanup and shared static/live image-load observer.
- `test/js/home_readouts_test.mjs`: local greeting/date, timestamp aging, patched failure
  metadata, resume updates and timer/listener teardown.
- `test/js/mail_reader_test.mjs`: async reader focus/latest-reply handoff, exact return
  scroll/focus, context fencing and teardown; local date formatting and independently
  aging fetch freshness, patched attributes and timer/resume-listener cleanup.
- `test/lovelace_web/live/home_overview_live_test.exs`: distinct connection summaries,
  shared/unattached membership, unknown/zero/stale counts, Home navigation and account isolation.
- `test/lovelace_web/live/home_live_test.exs`: shell, client commands, accessible/decorative
  branding, Lock POST/token structure, image URL allowlist and stage updates.
- `test/lovelace_web/live/workspaces_live_test.exs`: persistence, validation and unsaved-form
  preservation; navigation/save/cancel emit heading-focus events, rejected saves do not.
- `test/lovelace_web/live/mail_live_test.exs` and `connections_live_test.exs`: workspace/account
  navigation, management effects, explicit OAuth context and stale async/PubSub isolation;
  single-title reader/native disclosures, escaped bodies/metadata, result-context resets
  and retention of search/page on return without provider payloads in socket assigns.
- `test/lovelace_web/controllers/owner_controller_test.exs`: static unlock/setup, session
  revocation and real CSRF enforcement on Lock (missing/invalid denial, valid token acceptance).
  Asset tests pin local vendor/font files and retained licenses.
- `test/browser/ui_contract.mjs`, launched by `test/support/ui_browser.exs`: actual browser
  entrance/directional exit/gate and focus; corner/Lock computed visibility/focusability; static
  stage with/without JS; static/live image success/failure; native menus; workspace/account/
  Connections navigation; unsaved first-key wake, first-click activation and scroll preservation;
  scheduled idle expiration with a shortened disposable DOM timer; mid-reveal reduced motion;
  forced colors; desktop/narrow inbox/reader layouts; long-token wrapping and body type;
  native message/metadata disclosures and refresh preservation; reader Escape/wake;
  async Back row-focus/scroll restoration; real delayed loading transparency, stable status
  height and ordinary/reduced-motion/forced-color sweep behavior, including mid-load preference
  changes; off-origin requests, page errors and CSP events.

The browser gate is separate from `mix check`/hosted CI and requires an installed browser;
it fails rather than silently skipping when unavailable. See development guidance for its
isolation and deadlines. Native Node tests cover the actual three-minute timer, hidden/sleep
elapsed time, patches and animation interruption/replay deterministically. The browser suite
is not exhaustive: real tab suspension/sleep, Escape during every animation phase, full
keyboard tab-order traversal, contrast measurements and aesthetic evaluation of long-message
reading still merit manual review. Browser/aesthetic approval, assistive-technology testing, cross-browser checks
and hosted CI are distinct evidence, not claims inferred from these suites.
