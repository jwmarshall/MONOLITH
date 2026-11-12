# LOVELACE

A quiet place to orient your day.

LOVELACE is a personal homepage that runs locally on your Mac. Read Gmail,
optionally see today's Google Calendar agendas, and follow open GitHub pull requests.
Workspaces group separate accounts and GitHub personal/organization installations by area of life.

- Read-only: no sending mail, changing mailbox state, editing calendar events, or modifying GitHub repositories.
- One local owner; its password unlocks a dedicated macOS keychain and SQLCipher-encrypted SQLite database.
- Local-only: keep it on loopback, not a public server or tunnel.
- Startup is locked. Explicit Lock stops protected background work; visual idle/Escape does not.
- No password recovery. Existing plaintext data requires an explicit, stopped migration.

A glass interface keeps your work in front of the scenery.
[Optional generated scenery](docs/STAGE_DESIGNER.md) is opt-in and may incur API costs.

## Try it locally

After installing the [local prerequisites](docs/DEVELOPMENT.md#local-setup), run:

```sh
bin/lovelace setup
bin/lovelace server
```

Open <http://localhost:4321>, pair the browser using the code printed in the terminal,
and create your owner password and encrypted keychain. The app then guides your own
[Google project and OAuth setup](docs/GMAIL.md#2-google-cloud-setup), audience/test users,
Desktop client credentials, and Gmail connection. You can skip Gmail and resume later;
Calendar requires separate consent. No password recovery is available.
For a review without touching existing data, use the
[isolated fresh-onboarding instructions](docs/DEVELOPMENT.md#fresh-onboarding-without-resetting-existing-data).
GitHub uses App sign-in and selected personal/organization installations; see
[GitHub setup](docs/DEVELOPMENT.md#github).

## HTML design studies

Open [the ten-concept gallery](design-concepts/index.html), or serve only its portable folder:

```sh
python3 -m http.server 8176 --bind 127.0.0.1 --directory design-concepts
```

Visit <http://127.0.0.1:8176>. Tideline, Monolith, Amber Room, Stillwater and Nightfall
refine the cinematic identity; Orbit, Folio, Prism, Aurora and Atelier explore new visual
languages. Each is an independent single-page HTML study with local shared CSS/JavaScript,
full-image scenery, glass, an animated entrance, and fictional account-separated Home readouts.
These are design demos, not production routes or authentication screens; they request no password
and never connect accounts or call providers.

**Enter demo** plays the symbol trace and LOVELACE letter flips. Escape reveals the scenery
or cancels an unfinished entrance; click/type resumes an entered Home immediately.
**Replay unlock** restarts the visual demo, not the application vault. Reduced motion skips
the choreography. Mail, workspace and calendar controls open read-only sample details.

The ten backgrounds were generated through the existing one-shot Gemini confirmation workflow
using `gemini-nano-banana-2.1`, 16:9, 1K. Their prompts, completed attempt IDs, timestamps and
SHA-256 hashes are in [the asset manifest](design-concepts/backgrounds/manifest.json).
The application's prior scene direction and selected background were preserved.
No generation occurs when opening these pages.

The bundled Space Grotesk font is an unmodified copy of the
[pinned application font](priv/static/fonts/space-grotesk/README.md), SHA-256
`8e085aa438094f11487a836652edd5c054fa6a96f63fc7c282105ee3a4b08c07`,
with its [SIL Open Font License](design-concepts/fonts/OFL.txt). Other typefaces use
system serif/monospace fallbacks. The whole `design-concepts` folder can be copied as a unit.

### MONOLITH designer study

The [expanded MONOLITH study](design-concepts/monolith-study/index.html) defines the committed
**redesign and rebrand of LOVELACE as MONOLITH**. This change is scoped to the static study;
the running application, commands, backend and keychain identifiers are not migrated here.
All ten original demos remain unchanged. Serve it with the command above,
then visit <http://127.0.0.1:8176/monolith-study/>. Charcoal is the study’s only interface
theme; Settings contains focus and scenery preferences, not a palette selector.
Scene-direction palettes and light/dark identity proofs do not change the interface palette.

- **Identity:** the MONOLITH mark has no separate name; Outline and Solid describe its treatments.
  The guide opens with the mark introduction joined to four logo cards in both polarities,
  at display and 24/32/48px sizes. Above 1000px, the introduction places the mark description
  on the left and treatment guidance/actions on the right, separated by a fine rule.
  Narrower screens retain the stacked reading order. Shared lockup specifications and usage rules follow;
  the dedicated inline unlock-motion stage sits at the bottom. Rebrand announcement blocks
  are omitted from study pages. Download the outline SVG or jump directly to the animation
  from the mark introduction. Treatment and polarity controls affect that stage
  only. Replay is manual, with Stop and Escape restoring the complete identity; changing
  selection, leaving the view, scenery mode or printing cancels playback. Repeated Replay
  restarts one sequence, never overlapping runs. Reduced motion shows the static identity.
- **Views:** Home, workspaces, account-separated mail and reading, GitHub activity,
  Connections, Calendar, Scenes, Settings, unlock, pairing and first-run setup.
- **Components:** visual tokens, typography, controls, numbered account registers, forms,
  dialogs, feedback states, responsive behavior, accessibility and motion specimens.
  The navigation specimen pairs links on the left with their description on the right,
  stacking on narrow screens. Disabled form groups retain native fieldsets inside padded panels.
  Unit 04 pairs the horizontal ladder with measured vertical rhythm: 8px label/control,
  12px heading/copy, 16px related content, 24px groups, 32px header/content and 48px sections.
  Parent-owned grid gaps and zero child margins prevent doubled spacing; readable line heights
  are not forced onto a baseline grid. Specimens become one column at 800px, with stacked keys
  and 16px insets at 600px; semantic gaps remain unchanged.
  Semantic accents use architectural-instrument colors: cyan attention (`#70d6eb`),
  amber warning (`#f2bb63`), light vermilion danger (`#ff9c89`, existing `--error` token)
  and jade success (`#79d5b0`) in the Charcoal interface.
  Attention means worth reviewing, not a problem; warning names caution or a constraint;
  danger names failure or a scoped destructive action; success confirms a specific observed result.
  Reserve color for small icons, labels, counts and fine markers; keep card fills and
  ordinary controls neutral. Components includes side-by-side status specimens and
  Voice defines the same roles. Pair color with shapes and explicit text; small colored
  text belongs on dark glass with at least 4.5:1 contrast, not directly on scenery.
  Six original animated SVG signals explore a minimal, futuristic MONOLITH vocabulary:
  two check bars (healthy), four sequenced squares (loading), a squared question hook
  and dot (unknown), a stepped bar hourglass (waiting), separated connector brackets
  (disconnected), and the retained clipped warning triangle (attention). Components
  includes use-case guidance, 16/24/32px proofs and downloads from
  `design-concepts/monolith-study/signals/`. Shapes and labels must work without color or motion.
  All six repeat gentle, distinct cycles: a complete check lifting and settling (3.6s),
  clockwise loading squares (2.4s), a rocking question hook with a lifting dot (3.6s),
  hourglass bars transferring through a falling square (3s), outward-only connector
  separation (3.6s), and a double-lift exclamation inside a persistent warning outline (3s).
  The broken link's central gap never closes.
  Only loading implies an active read; unknown does not imply polling or progress.
  Reduced motion, print and inherited `--signal-motion: none` show complete, static geometry.
  Signals inherit text color, support forced colors and accompany explicit status labels
  rather than replacing them.
  Serve the study over HTTP: before first render, bootstrap awaits
  `MonolithViews.readySignals()` to fetch the six local SVG sources once, install their
  CSS once in the host document and cache inline SVG geometry. Rendered signals and
  downloads share those canonical sources; no external SVG `<use>` rendering is involved.
  The consumer API `MonolithViews.signal(state = 'healthy')` stays synchronous after
  initialization. A source-loading failure shows an error with a reload retry.
- **CSS:** [live legend and source reference](http://127.0.0.1:8176/monolith-study/#/css).
  `tokens.css` is the canonical, annotated public foundation, loaded before the consuming
  stylesheets: semantic colors, the Charcoal palette, spacing, typography, reading measures, controls
  and focus, layout, interface motion, layers and fixed brand presets. Existing product
  selectors and component specimens consume the same tokens. Components keeps role names
  rather than copied palette values; account and section type specimens match their consumers.
  The legend reads every declaration and usage comment from that file, with active computed
  values, color chips and token/usage search. Active values reflect the current output mode,
  including forced-colors and print overrides.
  A separate live stylesheet inventory identifies scoped variables and accessibility
  overrides, including signal artwork. The rendered reference uses the actual shared controls,
  fields, reading type and status signals—not a second demonstration implementation.
  The source viewer reads all six served CSS files as text; download the annotated token
  stylesheet directly. It introduces no build step, remote assets or provider requests.
  Token-source failures have an explicit retry; leaving the view cancels pending reads/listeners.
  Values are cached for the document lifetime; reload after editing source files.
  Add shared tokens as one declaration per line with a usage comment beneath an
  `/* @group Group name */` heading; the legend rejects unannotated declarations.
  Keep component preset/measurement knobs scoped. Literal content-fit media queries
  stay beside their layout rules, not in unusable breakpoint custom properties.
  The on-page design contract specifies ownership, composition, responsive behavior,
  contrast, focus, state semantics, reduced motion, forced colors and print.
  It describes the static rebrand target; `docs/UI_CONTRACT.md` still governs the running app.
- **Voice:** naming, tone, action labels, recovery messages and contextual state copy.
- **Proof:** view/state links, interaction paths, review notes and a checklist.
  **Study limits** consolidates frozen sample times, in-memory changes, local-only search,
  credential specimens and simulated scene requests. Shared subview-header placement belongs
  in **Components → Navigation and identity context**, alongside workspace-card controls.
  Product requirements remain in `docs/UI_CONTRACT.md`; token usage comments remain in `tokens.css`.
  Print the current review to paper or PDF using the browser print dialog.

The composition returns to the original demo’s oversized date, editorial grid, joined glass,
account numbering and fine rules. After entry, the sidebar itself contracts to a **64px bar**
(**48px at 760px and below**) with only the MONOLITH mark at the top. The same icon toggles
**Expand sidebar** / **Collapse sidebar**. On desktop, expansion widens that existing column
to **224px**, moving the content with its edge. At narrow widths the expanded sidebar sits
above the content in normal flow so the view is not squeezed into a sliver. No separate drawer,
overlay, backdrop or focus trap exists; Tab follows the normal page order. The sidebar contains
01 Home, 02 Workspaces, 03 Connections, 04 Scenes and 05 Settings, with Lock separated at the bottom.
Escape collapses it and returns focus to the icon; destination selection collapses it and focuses
the view heading. There is no separate mobile header or horizontal product navigation.
The full unlock screen retains the outline treatment; designer controls stay separate.
Regular glass cards use 71%-opaque backgrounds, open left/right edges, horizontal rules and
internal column dividers, matching the original MONOLITH demo. Text stays fully opaque.
Controls, focus indicators and dialogs retain their own backgrounds and outlines.
Working content has no top padding; its existing side and bottom spacing is retained.
The centered threshold retains full-image scenery and glass.
The Outline draws its **outer contour bottom to top** along two edges,
then its **inner creases top to bottom**, with overlapping strokes. The inline stage’s Solid
treatment reveals the silhouette bottom-up while negative-space creases descend: **rise and incise**.
Both use the same choreography: a completed-mark pause precedes the letter flips;
the lockup holds, lifts and dissolves. Each replay lasts about 5.2 seconds. Completed geometry
matches the static artwork. No shading, moving faces, autoplay or looping.
This study commits the design direction, not an already-completed production cutover.
The approved rebrand covers the full application and UI, project-owned libraries,
modules, OTP/configuration namespaces, paths, commands, tooling and storage/keychain
names: **MONOLITH**, `Monolith`/`MonolithWeb`, `:monolith` and `monolith`.
Third-party package names remain unchanged. There are no users and local data is
replaceable; no preservation migration, compatibility layer or legacy alias is required.

For implementation, use the [distilled MONOLITH design rules](docs/MONOLITH_DESIGN_SYSTEM.md)
and [reviewer/skill routing](docs/REVIEWERS.md#monolith-rebrand-routing). The project-local
MONOLITH Scopewright reviewers and Skillwright workflows enforce that target while
retaining real product/security behavior, not importing the study simulator.
The current source and unmigrated UI contract remain evidence of today's implementation,
not a veto on the full rename. Preparing these artifacts does not rename application source.

Open **View / state** for authored scenarios, or follow product navigation.
Hash URLs preserve destinations and mail context. Ordinary product-route reloads replay
the entrance gate; add `?proof=1` to skip it for direct proofing. Escape and visual idle
reveal scenery without locking; click or type resumes current work.
Reduced motion skips entrance choreography.
Home proofing distinguishes first-read unknown counts, an observed zero-unread Personal
account, no integrations and a failed update retaining labeled counts. Workspace labels
follow the study's editable names and memberships rather than fixed fixture labels.
Home keeps its location, agenda timezone and account identities without account-boundary
slogans, provider-scope qualifiers or an explanatory footer. Product navigation has no tagline;
scenery remains available through Escape and visual idle rather than a View scenery button.
The proof toolbar is not proposed product chrome.

All data is fictional. Controls change in-memory specimens only: no authentication, keychain,
provider access, paid generation, or persistent storage. Reload resets edits and review notes.
Scene choices reuse existing local backgrounds. Secret fields are non-editable specimens;
“Preview unlock” only plays the transition. The selected identity is not a trademark-clearance claim.
Copy the entire `design-concepts` folder to retain local fonts, scenery and original demos.

## Development

Built with Elixir, Phoenix LiveView, Ash, and SQLite.

```sh
bin/lovelace check           # format, compile, lint/security, tests, and assets
bin/lovelace audit           # online dependency audit
bin/lovelace mix test.ui     # browser checks; requires Chrome/Chromium
```

[Development guide](docs/DEVELOPMENT.md) · [Gmail](docs/GMAIL.md) ·
[Calendar](docs/CALENDAR.md) · [UI and accessibility](docs/UI_CONTRACT.md)
