# LOVELACE — visual and interaction contract

This is the current contract for all owner, workspace and mail surfaces. Keep visual and
interaction decisions here and durable product/safety rules in [AGENTS.md](../AGENTS.md).
Later approved decisions replace old requirements rather than accumulating a chronology.
Verify implementation in code; the coverage map below is not evidence that checks passed.

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

- `/` is Home, the default after ordinary unlock. Reload and copied deep links restore their
  destination; a protected deep link resumes after unlock when its local return URL is safe
  and bounded. Escape/idle wake preserves the current view, scroll and forms; it never navigates
  Home. Successful Gmail consent returns to the receiving workspace; Calendar consent
  returns to its global provider page for calendar selection.
- A centered navigation bar contains **Home**, **Workspaces**, **Connections**, and **Scenes**,
  in that order. These are native links using LiveView patches, with usable `href` destinations
  for copying/opening in a new tab; current destinations are identified with `aria-current`. Home is a visible text control, never the decorative
  corner monogram. Lock stays separate. Top-nav Connections always opens the global
  `/connections` overview, including from workspaces and provider pages. No workspace query
  or workspace-return control is attached; browser Back retraces the actual origin.
  Gmail inboxes likewise have no redundant Home button.
- Home opens with a restrained greeting and date in the browser's local time, updated
  across midnight/resume. Home, Workspaces, Connections and Scenes use the same content width and
  alignment from the shared directory container; Home has no narrower inner cap. Reserve
  symmetric scrollbar gutters so scrolling pages do not shift the content plane. Keep copy
  functional and minimal: no “Your day” eyebrow, slogans or explanatory footer. Numeric
  account totals are labeled simply **unread**. No clock, message previews, total across
  accounts or speculative widgets. The separately approved read-only Calendar agenda
  below complements Gmail's daily orientation.
- Home pairs compact Gmail rows with today's Calendar agenda in two open columns on desktop,
  aligned at their section headings. Stack Gmail above Calendar when either column would become
  cramped; retain the shared directory width, not separate cards or a narrower dashboard shell.
  Keep the greeting/date on one restrained line where space permits. Home omits routine checked
  statuses (including “not checked yet”) and Calendar Refresh controls. Keep loading, error and
  locally aging stale warnings visible; workspace/Connections timestamps and refresh remain unchanged.
  Unknown unread totals use a dash with an accessible unavailable label, never a fabricated zero.
  Calendar setup is a compact empty state linking directly to Connections → Calendar.
- Gmail readouts use quiet horizontal rows: one per non-disconnected connection, including
  connections with no workspace membership. Each shows identity, workspace names, actual
  unread inbox conversation total and independent count health. Home shows stale warnings rather
  than routine successful-check timestamps; the underlying observation still ages locally.
  Clicking a row opens only that account's read-only inbox without attaching it anywhere.
- Unknown counts are not zero. Failed updates retain known counts as stale; elapsed time
  marks observations stale after three minutes, independent of unrelated mail-page success.
  Home rendering reads persisted metadata, never provider calls or cached message content.
  Empty/loading/error/reconnect states remain explicit, with recovery through Connections.

- Calendar shows account-separated browser-local today's agendas on Home and workspace
  detail, without a unified timeline. Event titles, calendar names and Google Calendar links align
  to the left edge of each item; time/all-day/ongoing labels sit at the top-right, including on narrow
  screens. Never display descriptions, attendees or remote content.
  Connections → Calendar owns optional consent and local calendar selection (Google-selected
  defaults, shared calendars included). Unknown/loading/failure are not an empty agenda;
  partial results are labeled. Observations age locally, stale/error states retain their
  real timestamps, and refresh respects rate-limit cooldowns. The browser rechecks the
  day across midnight/DST/resume; another timezone's cached context must not be rendered
  as this view's today. Calendar content is not retained in LiveView socket assigns.
  Workspace removal is not global disconnect; both services share the Google credential.
  See [CALENDAR.md](CALENDAR.md) for bounds and lifecycle.

- Workspaces represent areas of life. **Quiet sea-glass cards supersede the earlier
  typographic/no-card directory**. Use generous native link surfaces and separate native
  management disclosures for rename; opening and management are siblings, never nested controls.
  Create/rename use native modal dialogs with trapped focus, labelled headings and inline
  validation. Cancel/Escape closes only the dialog, restoring focus without entering scenery
  mode. Unrelated patches preserve the draft; invalid submissions keep the dialog open.
  The visual idle timer pauses while a modal is open and resumes on dismissal;
  this is not an authentication or privacy change.
- `/connections` is a quiet provider overview with Gmail, Calendar and Gemini links and
  short purpose labels, not a default Gmail page or combined health dashboard. It mounts
  no provider form and makes no Keychain/provider probe. Opening a provider focuses the
  heading; each provider offers **All connections** back to the overview.
- Provider pages have a **Gemini / Gmail / Calendar** subnav on the same row as the title
  on desktop (wrapping below on narrow screens), with only the selected provider mounted.
  Native links identify the provider with `aria-current`; switching preserves focus on the
  chosen subnav control. Provider paths are `/connections/gmail`, `/connections/calendar`
  and `/connections/gemini`. Each supports direct GET, reload and new tabs; Gemini credential
  POSTs return directly to Gemini without exposing credentials to normal request instrumentation.
  Escape/idle preserves selection. Re-selecting the active provider does not discard forms;
  provider changes enter history and remove the previous provider's unsaved form content.
- Workspace detail prioritizes separate integration/account tiles, never an aggregate inbox.
  **Add integration** is a focused panel for reusable connections or connecting Google;
  Gmail and opt-in read-only Google Calendar reuse account identities, not a speculative
  provider catalog. Google Gemini
  is an **app-wide scenery connection** in global Connections, separate from Gmail accounts;
  it is never attached to a workspace or included in Gmail health/counts. Its API-key forms
  are ordinary authenticated, CSRF-protected POSTs, not LiveView credential events. Display
  only Keychain availability/key presence, never a returned key or unverified Google health.
  Saving/removing does not generate, probe Google or change the startup opt-in/cooldown.
  Explain possible charges, optional startup generation, explicit Scenes requests and
  preserved imagery on key removal.
- **Remove from workspace** detaches locally; global **Connections** owns health, reconnect
  and confirmed **Disconnect everywhere**. Global Gmail accounts use compact rows with
  identity/status beside actions on desktop and a wrapping layout on narrow screens.
  **Add Gmail account** opens a native modal; the new-connection form is absent until opened.
  Cancel/Escape dismisses only the dialog and restores the Add button. Unrelated metadata
  patches preserve its receiving-workspace choice. Global connect/reconnect forms explicitly
  select the receiving workspace, preserving identity and membership context.
- Gmail Connections offers an explicit per-account **Check Keychain**, separate from
  Google reconnect/disconnect. Run it asynchronously, one at a time, with announced
  safe error categories and an observation timestamp; never expose the token. Explain
  that an unlocked keychain can still deny item access and a readable token does not
  verify Google. Checks do not change permissions, contact Google, refresh mail or
  clear persisted health/freshness. Fence delayed results across connection generations
  and leaving/reentering Connections. Keep recovery guidance in a native disclosure;
  no automatic permission prompts or helper rebuilds.
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
- Scenes keeps all published local images, with no total count cap; the gallery shows
  20 per page with native Newer/Older controls. Dates when known, the actual active background
  and latest-attempt states stay honest. Refresh status only reads local state.
  Confirmed manual requests have no daily cooldown, including after a failed/successful
  attempt; the persisted 24-hour cooldown applies to automatic startup only. An unconfirmed
  reservation blocks manual requests to avoid overlap, with an explicit explanation rather
  than an invented completion time. Disabled controls use a normal cursor, not a waiting cursor.
  Use scene changes the app-wide background and persists across reloads; a new successful
  generation becomes active. Missing/corrupt previews cannot be selected. Generate opens a
  native confirmation dialog warning that each request can incur charges, even with failed
  or unknown outcomes, and that there are no automatic retries. Cancel/Escape restores trigger focus and
  does not request generation. Confirmed work survives navigation; startup opt-in remains
  independent. Preserve modal idle/focus behavior and gallery selection during scenery wake.
- Meaningful views have URLs: `/workspaces`, `/workspaces/:workspace_id`, its `/integrations`
  setup panel, `/accounts/:account_id/mail`, and workspace-scoped
  `/workspaces/:workspace_id/accounts/:account_id/mail`. Readers append `/threads/:thread_id`.
  Submitted searches use `q` and Gmail pagination uses `page_token`; both remain in reader URLs
  for returning to results. Search text is consequently visible in browser history/copied links,
  but is filtered from Phoenix parameter logs. Connections URLs have no workspace context.
  Obsolete/irrelevant query parameters are removed with history replacement; old root-query
  navigation bookmarks still resolve to canonical paths. Consent/credential feedback queries
  carry only safe status categories and are consumed on entry. Scenes uses `/scenes?page=N`
  (page one omits the query).
- Navigation adds browser history; Back/Forward reapply the URL without remounting the shared
  stage. Reload/new tabs resolve the same view, subject to current account/workspace access.
  Invalid/unavailable destinations recover visibly to Workspaces rather than retaining another
  account's content. Dialogs, unsaved drafts, disclosures, scenery focus and idle state are not
  URL state. There is no cross-tab directory synchronization.
- Loading, empty, stale, offline, expired-credential, rate-limited and failed states must
  remain truthful and distinguishable. Account context stays explicit in mail views;
  disconnected integrations must not appear operational. Detailed Gmail boundaries live
  in [GMAIL.md](GMAIL.md).

## Images, accessibility and preferences

- Reveal a generated image only after it successfully loads. Failed loads leave the
  installation's local bundled JPEG default, not a broken-image replacement. Three
  owner-approved images ship locally; choose one once per installation, preserving it
  across reload, navigation and scenery wake. Static owner pages (including without JS)
  and live stages share that choice. Keep generated imagery restricted to validated
  same-origin PNG/JPEG digest routes and bundled imagery to the exact asset allowlist;
  no provider-hosted/arbitrary URL substitution. Defaults are not generated gallery
  entries. Rendering only reads local preferences; it never initializes or generates.
  Generation and default-choice persistence rules belong in `STAGE_DESIGNER.md`.
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
for commands. Report actual executed results and unrun checks in the task response;
historical results do not certify a new change.

- `test/js/brand_reveal_test.mjs`: choreography, interruption/replay, reduced motion and teardown.
- `test/js/workspace_entrance_test.mjs`: gate completion, focus handoff, patch continuity and teardown.
- `test/js/ui_browser_runner_test.mjs`: early normal/signal Chrome exit must fail promptly,
  not hang on an already-fired event or report success; no real browser/app is launched.
- `test/js/workspace_idle_test.mjs`: elapsed-time/activity/wake rules, patches/hidden tabs,
  modal idle suspension/resume, timer cleanup and shared static/live image-load observer.
- `test/js/native_modal_test.mjs`: opening/focus, sticky open state, Escape isolation,
  server-owned dismissal, listener cleanup and focus restoration (including disabled triggers).
- `test/js/calendar_agenda_test.mjs`: browser-local midnight/DST boundaries,
  midnight/resume/reconnect notifications, event local-time/ongoing labels and teardown.
- `test/lovelace/calendar_test.exs` and `test/lovelace_web/live/calendar_live_test.exs`:
  account/context/generation fencing, selection, bounded/truncated results, cooldown,
  freshness/retention, escaped render-local events and exclusive Connections navigation.
- `test/lovelace/integrations/google_calendar_test.exs` and
  `test/lovelace_web/controllers/google_calendar_oauth_test.exs`: read-only requests,
  strict provider parsing, explicit optional scopes, identity/generation-bound consent
  and refusal of late callbacks across disconnect/reconnect.
- `test/js/home_readouts_test.mjs`: local greeting/date, timestamp aging, patched failure
  metadata, resume updates and timer/listener teardown.
- `test/js/mail_reader_test.mjs`: async reader focus/latest-reply handoff, exact return
  scroll/focus, context fencing and teardown; local date formatting and independently
  aging fetch freshness, patched attributes and timer/resume-listener cleanup.
- `test/lovelace_web/live/navigation_live_test.exs`: native deep links, global provider
  overview, obsolete-query/bookmark normalization, workspace history, direct account/thread/search/page entry, reload-equivalent mounts, URL
  transitions, invalid/unavailable recovery and account fencing. Owner controller/auth tests
  cover safe requested destinations through unlock and reject unsafe/form-injected returns.
- `test/lovelace_web/live/home_overview_live_test.exs`: distinct connection summaries,
  shared/unattached membership, unknown/zero/stale counts, Home navigation and account isolation.
- `test/lovelace/stage_designer/bundled_scenes_test.exs`: fresh-database default reads,
  immutable initialization across connections/restarts and concurrent boots, authorization,
  pinned JPEG hashes/validation and independence from generated scenes/reservations.
- `test/lovelace_web/live/scenes_live_test.exs`: exclusive Scenes navigation, truthful
  empty/missing/unconfirmed states, immediate manual eligibility after success/failure,
  confirmed-only requests with safe fake-vault failure, paginated access to all saved images,
  persistent selection and app-wide stage updates. Backend scene/coordination tests cover
  reservation policy, selection during generation, duplicate output and publication/notification exclusion.
- `test/lovelace_web/live/home_live_test.exs`: shell, client commands, accessible/decorative
  branding, Lock POST/token structure, image URL allowlist and stage updates.
- `test/lovelace_web/live/workspaces_live_test.exs`: persistence, validation and unsaved-form
  preservation in dialogs; navigation emits heading-focus events while modal dismissal
  leaves trigger focus restoration to its hook; rejected saves keep the modal open.
- `test/lovelace_web/live/gemini_connection_live_test.exs` and
  `test/lovelace_web/controllers/gemini_credentials_test.exs`: safe presence/failure states,
  ordinary POST forms, auth/revocation/CSRF, bounded input and secret-free Phoenix telemetry.
  Backend credential tests cover owner-only actions, validation, exception containment,
  separate Keychain framing and refusal by an outdated helper; tests use fake vaults only.
- `test/lovelace_web/live/mail_live_test.exs` and `connections_live_test.exs`: workspace/account
  navigation, management effects, explicit OAuth context and stale async/PubSub isolation;
  single-title reader/native disclosures, escaped bodies/metadata, result-context resets
  and retention of search/page on return without provider payloads in socket assigns.
  Credential-check tests cover local-only safe results, account/generation fences,
  denied actors, native error sanitization and unchanged persisted sync metadata.
- `test/lovelace_web/controllers/owner_controller_test.exs`: static unlock/setup, session
  revocation and real CSRF enforcement on Lock (missing/invalid denial, valid token acceptance).
  Asset tests pin local vendor/font files and retained licenses.
- `test/browser/ui_contract.mjs`, launched by `test/support/ui_browser.exs`: actual browser
  entrance/directional exit/gate and focus; corner/Lock computed visibility/focusability; static
  stage with/without JS; static/live image success/failure; native menus; workspace/account/
  Connections navigation; workspace modal focus/inertness, Escape-only cancellation,
  idle draft preservation, save/cancel focus restoration, first-click activation and scroll preservation;
  keyboard local credential checks, timestamped unverified-Google results and Keychain
  help without credential disclosure or horizontal overflow; five compact Gmail rows
  and the new-connection modal's required workspace choice,
  Cancel/Escape focus and desktop/narrow/forced-color layout; title-row provider subnav,
  keyboard switching with focus retained, mutually exclusive provider interfaces, scenery
  wake preserving selection and credential POSTs returning to Gemini;
  Gemini's ordinary credential POST to a fake vault, empty return form and truthful key state;
  compact side-by-side Home readouts at desktop/laptop widths, stacked tablet/narrow readouts,
  no routine checked statuses or Home Calendar Refresh, retained stale warnings and workspace controls,
  unknown unread labels, compact empty Home and direct Calendar setup;
  optional Calendar Home/workspace agendas with safe explicit links, Google-selected and
  shared-calendar selection, exclusive Calendar Connections and ordinary consent POSTs,
  desktop/narrow/forced-color Calendar layouts and fixture screenshots;
  an empty-installation pass with the actual bundled defaults, no generated images,
  no-JS/static/live parity, decoded JPEGs and unchanged default across reload/navigation/wake;
  scheduled idle expiration with a shortened disposable DOM timer; mid-reveal reduced motion;
  forced colors; desktop/narrow inbox/reader layouts; long-token wrapping and body type;
  native message/metadata disclosures and refresh preservation; reader Escape/wake;
  async browser-Back row-focus/scroll restoration; real URL Back/Forward, global Connections overview/provider
  navigation, obsolete-query cleanup and direct Gemini reload, workspace reload and copied conversation/search/page links; real delayed loading transparency, stable status
  height and ordinary/reduced-motion/forced-color sweep behavior, including mid-load preference
  changes; Scenes keyboard navigation, gallery dates/previews, confirmation Cancel/Escape
  and focus restoration, read-only refresh, cross-tab selection, reload persistence, narrow
  and forced-color gallery/dialog layouts; off-origin requests, page errors and CSP events.

The browser gate is separate from `mix check`/hosted CI and requires an installed browser;
it fails rather than silently skipping when unavailable. See development guidance for its
isolation and deadlines. Native Node tests cover the actual three-minute timer, hidden/sleep
elapsed time, patches and animation interruption/replay deterministically. The browser suite
is not exhaustive: real tab suspension/sleep, Escape during every animation phase, full
keyboard tab-order traversal, contrast measurements and aesthetic evaluation of long-message
reading still merit manual review. Browser/aesthetic approval, assistive-technology testing, cross-browser checks
and hosted CI are distinct evidence, not claims inferred from these suites.
