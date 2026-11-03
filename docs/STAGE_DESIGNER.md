# LOVELACE stage designer

## Behavior

LOVELACE can generate a background through the **server-side Gemini Developer API**
on application startup when opted in, or through an explicitly confirmed request in
**Scenes**. It never generates from a page load, LiveView reconnect, gallery/status refresh,
or inactivity event. One locally bundled JPEG remains underneath locally served generated imagery.
Scenes includes a saved, guided **Scene direction** editor and an expandable exact prompt.
There is no scheduled worker. Scenes shows the retained local gallery,
latest attempt status and manual eligibility; unknown legacy image dates are labelled.
An in-server generation broadcasts updates to connected LiveViews. An operator invocation
in a separate BEAM process updates files/SQLite but not the running server's local PubSub;
refresh the homepage to load that result.

Before a direction is saved, the configured prompt provides architectural curation: original quiet brutalist forms,
distant landscapes, charcoal and restrained amber light, negative space, no people,
lettering, logos, busy foregrounds, or private dashboard context. The default is the
documented stable, high-efficiency `gemini-nano-banana-2.1`, `16:9`, `1K`. 1K is a provider
tier, not full desktop-native resolution or a visual-quality guarantee.

- One asynchronous attempt on an **eligible application-process startup**. Browser
  loads do not start work. Scenes requests require explicit confirmation of possible API
  charges and work independently of the startup-enabled setting. There is no daily timer
  while the application stays running. Manual requests use a supervised, nonretrying task
  that survives leaving the view. Confirmed manual requests have no daily cooldown,
  including after failure/success, but refuse any existing unconfirmed (`generating`)
  reservation to avoid overlapping requests. An old reservation is not presumed dead
  merely because time elapsed; there is no automatic recovery or guessed retry.
- SQLite persists an attempt reservation **before** contacting Gemini. The minimum
  **automatic-startup** interval is 24 hours, including failed, interrupted, and unknown outcomes.
  Every manual reservation also advances that startup cooldown; it does not impose a manual cooldown. A missing
  image does not bypass that cooldown; neither does restarting the server repeatedly.
- A version-checked Ash update allows only the winning concurrent claimant to contact
  Google. No database transaction spans HTTP. No automatic HTTP or worker retries.
- Previous imagery stays visible while generating and on failure. Successful publication
  updates the manifest and open LiveViews through application-wide PubSub, not mailbox topics.
- Keep **all distinct successful images**, with no total count cap or automatic eviction
  of published scenes. The Ash scene catalog is authoritative; gallery reads validate at
  most 20 scenes per page, newest first. Disk use grows with successful generations.
  The bounded singleton history is only a recent background-fallback cache, not retention
  authority. Invalid/missing selected files fall back through recent images, then the installation's bundled default.
  **Use scene** can activate any catalog image, including an older gallery page, without
  generating or changing cooldowns. The next successful generation becomes active.
- Storage writes/publication and destructive cleanup share nonexpiring cross-BEAM
  exclusion on the configured storage root. Cleanup checks the committed catalog
  under that exclusion; a delayed publisher's old fallback list is never deletion authority.
  Publication commits before a separate pruning critical section, so rollback cannot
  resurrect references to deleted files. HTTP remains outside both sections.
- Stale unreferenced generated images and interrupted temporary writes are reconciled
  on eligible/cached startup checks after a five-minute grace period. Active writes
  are protected by exclusion, not age guesses. Brief extra files can exist during
  publication/recovery. See [storage coordination](STORAGE_COORDINATION.md): keep
  the private `.stage-coordination.sqlite3` identity for the lifetime of a shared root;
  never unlink/replace it while any LOVELACE process may use that root.

## Saved scene direction

Scenes offers guided subject (architecture, landscape, abstract), setting, light and palette
choices, with an expandable exact prompt. Draft changes update the preview but do not
change the saved default. Save explicitly before generating, or discard to restore the
active prompt. Status refresh, background updates and Escape/idle wake preserve drafts
and the prompt disclosure. Navigation away may discard unsaved choices.

The app-wide Ash direction singleton is only written by an owner-authorized save. Reads
never initialize it. Until the first save, `LOVELACE_STAGE_PROMPT` (or its built-in default)
remains the exact effective prompt. Saving adopts the guided choices and supersedes that
configuration for **all new manual and already opted-in startup generations**, across restarts.
It never generates, checks credentials, changes startup opt-in, alters cooldowns or affects
existing images. Direction read failures block generation rather than silently falling back.
Apply the additive scene-direction migration before using the editor.

The composed prompt always preserves quiet negative space, a low-detail center and
exclusions for people, lettering, logos and interface elements. Only allowlisted generic
art direction is accepted, with no free-text private context. The cost dialog also exposes
the exact prompt for its request. Manual confirmation checks that the saved prompt has not
changed since review; a mismatch refuses generation before reservation/provider access.
Already-dispatched work uses its captured prompt even if the default is subsequently edited.
Saved direction is a default for future images, not a record of past images' prompts.

## Bundled installation default

Three owner-approved existing scenes ship as local JPEG assets in
`priv/static/images/scenes/`, with provenance and SHA-256 pins recorded there. Their
private originals are unchanged. A separate Ash `DefaultScene` singleton chooses one
randomly on first application startup and preserves it across restarts; this happens
synchronously before the endpoint serves pages, independently of generation opt-in.
Reinitialization is an immutable upsert, including concurrent application starts.
Page rendering only reads the choice and never generates or initializes it. If the
preference is absent/unreadable, the first allowlisted bundled image is a deterministic
fallback until initialization succeeds. Apply the additive default-scene migration
before restarting an existing installation.

Static owner pages (including no-JavaScript unlock) and LiveViews share this default
when no generated scenery is available, and retain it under generated images while
loading or on image-load failure. It does not change on navigation, reload or scenery
wake. Generated scene selection/publication still takes precedence. Bundled defaults
are not catalog entries, do not invent generation dates, and are outside generated
storage cleanup; an installation without generated images still has an empty Scenes
gallery. No provider or Keychain access is involved in default choice/rendering.

## Inactivity / scenery mode

The [visual and interaction contract](UI_CONTRACT.md) owns focal-plane, inactivity,
entrance, static/live image-load, accessibility and preference behavior. The idle setting
is listed below; scenery mode is visual only, not authentication. No idle/wake/page event
starts generation.

## Gemini connection and local setup

The external **dotenvx 2.38.2** CLI was used; no npm dotenv package or Elixir dotenv loader
was added. Install a reviewed version of the [official CLI](https://github.com/dotenvx/dotenvx)
on another machine. The private local `.env` contains encrypted non-Gemini credentials and startup settings.
The Gemini API key is now entered in **Connections → Gemini** and stored in the
macOS Keychain under the separate `LOVELACE Gemini` service, never alongside Gmail tokens.
`GEMINI_API_KEY` is no longer read and has no fallback. The dotenvx decryption key is in
private `.env.keys`; both environment files are ignored and mode `0600`. `.env.example` is deliberately readable, credential-free, and disabled by default.

Eligible restarts may incur a charge. A previously authorized generation or working
background is not standing authorization for further provider calls. Model metadata
access alone does not establish billing or quota.

For a **fresh checkout only**, from the repository root:

```sh
# Never overwrite an existing local setup.
test ! -e .env && test ! -e .env.keys && (
  umask 077
  cp .env.example .env
  dotenvx encrypt -f .env --no-native --no-armor --no-1password --no-bitwarden &&
    chmod 600 .env .env.keys
)
```

Create an API key in [Google AI Studio](https://aistudio.google.com/api-keys), in a project
with appropriate billing/quotas. Build the native helper explicitly with
`LOVELACE_STAGE_ENABLED=false mix lovelace.keychain.build`, unlock LOVELACE, and enter the
key in **Connections → Gemini → Add API key**. Replace/remove it there too. Keys
travel through an authenticated, CSRF-protected ordinary POST before Phoenix request
instrumentation, not LiveView events/assigns. The documented stock Bandit in-process conn
metadata exception still applies. The stored key is never rendered back to the browser.
Keychain access is local-only, nonsynchronizing, and fails closed if unavailable/locked.
Saving checks format/storage only, not provider access, billing, quota or generation.
It does not trigger a request, change opt-in settings, or bypass cooldowns. Removing a key
keeps scenery/cooldowns and cannot cancel a request that already acquired the key.

**Migrating an existing setup:** manually re-enter your key in Connections. No automatic
import or inspection of private environment files is performed. Remove the obsolete
`GEMINI_API_KEY` setting from your private encrypted setup using your own dotenvx workflow;
it is ignored even if still injected. Existing imagery and reservations are unchanged.
Rebuild the helper after updating its source (the previous Gmail-only helper will safely
refuse Gemini operations).

```sh
# Explicit opt-in to paid startup generation:
dotenvx set LOVELACE_STAGE_ENABLED true -f .env --no-native --no-armor --no-1password --no-bitwarden
chmod 600 .env .env.keys
```

Migrate before activating/restarting; do not assume a private database is up to date:

```sh
LOVELACE_STAGE_ENABLED=false mix ecto.migrate
dotenvx run --strict -f .env --no-native --no-armor --no-1password --no-bitwarden -- mix phx.server
# Interactive variant: replace mix phx.server with iex -S mix phx.server
```

Plain Mix does not load `.env`. Existing shell variables take precedence over dotenvx;
avoid stale overrides. Do not `source .env`. Configuration changes require restarting
the application. Any command starting the OTP application can invoke the startup task;
force `LOVELACE_STAGE_ENABLED=false` for development/maintenance commands that should
not generate. Test runtime always disables the real startup task, regardless of the flag.
Production still needs `DATABASE_PATH`, `SECRET_KEY_BASE`, `PHX_SERVER=true`, and built
assets. Packaged releases migrate the schema before starting the generation task.

Never paste keys into chat or command history, or use verbose/debug logging and environment
dumps. Keep `.env.keys` in a separately protected backup; losing it loses access to the
ciphertext. Do not commit either private file, even ciphertext. Encryption does **not**
protect the plaintext private-key file, process environment, database, or image files
from processes running as the same user (including development tooling such as Tidewave).
Only generic art direction is persisted; the key is a sensitive transient Ash action
argument at save time, never database state, application configuration, or a LiveView assign.

## Configuration

| Variable | Default / constraint |
| --- | --- |
| Gemini API key | Connections UI → macOS Keychain; resolved only at the server HTTP boundary. `GEMINI_API_KEY` is ignored |
| `LOVELACE_STAGE_ENABLED` | `false` by default; exact `true`/`false` |
| `LOVELACE_STAGE_MODEL` | `gemini-nano-banana-2.1`; explicit safe model ID |
| `LOVELACE_STAGE_ASPECT_RATIO` | `16:9`; also `21:9`, `4:3`, `3:2`, `1:1` |
| `LOVELACE_STAGE_IMAGE_SIZE` | `1K`; also `2K`/`4K`, subject to validation limits/model support |
| `LOVELACE_STAGE_REFRESH` | `on_startup` only |
| `LOVELACE_STAGE_MIN_REFRESH_HOURS` | `24`; range 24–8760; cannot lower the minimum below a day |
| `LOVELACE_STAGE_MAX_ATTEMPTS_PER_STARTUP` | `1` only |
| `LOVELACE_STAGE_MAX_RETRIES` | `0` only |
| `LOVELACE_STAGE_TIMEOUT_SECONDS` | `120`; range 1–120, includes an overall deadline |
| `LOVELACE_STAGE_STORAGE_DIR` | `./data/stage-designer`; private, persistent, gitignored; use an absolute release path |
| `LOVELACE_STAGE_RETAIN_COUNT` | Obsolete and ignored; published scenes have no total storage-count cap |
| `LOVELACE_STAGE_PROMPT` | Initial generic brief; 1–8000 bytes, no private information. Superseded after a direction is saved in Scenes |
| `LOVELACE_WORKSPACE_IDLE_MINUTES` | `3`; range 1–60 |

Image files and the directory are owner-only. Digest URLs serve only catalog-registered,
validated original PNG or JPEG bytes: `.png` / `image/png` and `.jpg` / `image/jpeg`.
Declared MIME must match the bytes, stored extension, and requested extension. No renamed
JPEG-as-PNG, transcoding, arbitrary paths, or provider-hosted URLs are allowed. Existing
PNG/JPEG images remain compatible. The additive scene-catalog migration preserves existing
registered imagery and known timestamps; previously evicted files cannot be recovered.

Images are bounded to 10 MiB, 8192 pixels per side, and 16 million pixels total; streamed
provider JSON is capped at 16 MiB. PNG checks cover chunks/CRC, static-image structure,
scanlines, and bounded inflation. JPEG header preflight bounds dimensions **before**
native loading; Vix's JPEG-specific loader fails on decoder warnings and evaluates all
pixels before accepting the image. Baseline/progressive 8-bit JPEG and grayscale are
supported; unsupported frames/precision fail closed. Other formats, including WebP/APNG,
are rejected. Some 4K aspect ratios intentionally exceed these safety limits.

Original bytes and embedded provenance are retained, not stripped or re-encoded. This
preserves metadata but does **not** authenticate C2PA/SynthID or certify complete image
format conformance. Native decoding adds a maintained parser dependency, not a sandbox.

## Documentation review: output formats and validation

The Gemini Developer API's current [ImageConfig](https://ai.google.dev/api/generate-content#ImageConfig)
and [public v1beta discovery schema](https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta)
do not offer a reliable PNG selector in the existing `imageConfig` path. The newer
`generationConfig.responseFormat.image.mimeType` schema explicitly supports `IMAGE_JPEG`;
that is not the text-only `generationConfig.responseMimeType`. We retain the existing
supported aspect-ratio/size request and accept both validated JPEG and PNG output.

Do not copy similarly named Imagen `parameters.outputOptions.mimeType` or Vertex AI
`imageConfig.imageOutputOptions.mimeType` fields into this Developer API request. The
[image guide](https://ai.google.dev/gemini-api/docs/image-generation) and examples have
inconsistent file extensions; the actual MIME and bytes, not a `.png` example filename,
determine encoding. Do not infer a rejected response's encoding from a filename.

[PNG section 11.2.3](https://www.w3.org/TR/png-3/#11IDAT) instructs decoders to ignore unused
bytes after the compressed stream in the final IDAT chunk. The validator now uses OTP's
[documented zlib API](https://www.erlang.org/doc/apps/erts/zlib.html), permits this padding,
and still requires complete zlib output, valid scanlines/CRCs, and no trailing bytes after
IEND. It no longer depends on undocumented `inflateInit/3` strict mode.

JPEG decoding uses pinned [Vix 0.42.0](https://hexdocs.pm/vix/0.42.0/Vix.Vips.Operation.html#jpegload_buffer/2)
and libvips, with [warning-level failure](https://www.libvips.org/API/current/enum.FailOn.html).
Full evaluation is required because loading alone is lazy. Decoder error text is never
logged. See `DEVELOPMENT.md` for native build/licensing and verification notes.

## Privacy, costs, and failure handling

Consult the current official [model documentation](https://ai.google.dev/gemini-api/docs/models/gemini-nano-banana-2.1),
[image guide](https://ai.google.dev/gemini-api/docs/image-generation),
[pricing](https://ai.google.dev/gemini-api/docs/pricing), and
[terms](https://ai.google.dev/gemini-api/terms) before activation. This model's image
generation is paid. Use project quotas and billing alerts independently; alerts are not
a hard spending cap. The application has no dollar-denominated spending cap. Synthetic
tests do not certify provider availability, billing, visual quality or native Keychain
signing/migration.

Unpaid Gemini services generally permit product-improvement use and human review;
regional exceptions apply. Paid terms generally exclude product-improvement use by default,
but do not promise zero retention or no abuse review. Review project
[logging/sharing settings](https://ai.google.dev/gemini-api/docs/logs-policy) and leave
dataset sharing disabled. Requests set `store: false`, but that does not override abuse
monitoring or contractual retention. Never include email, names, calendars, projects,
or other private context. No search grounding, remote references, or browser Google calls.

Gemini uses a private Req adapter over unpooled Mint, not Finch's credential-bearing
request instrumentation. Its transport events contain only numeric timing/status and
allowlisted categories, never requests, payloads, credentials or raw exceptions.
Req/Mint upgrades must re-audit this boundary and run its actual loopback transport
regressions; `Req.Test` alone is not transport-containment evidence.

Failures log the failing stage, a safe error category, HTTP status when available, and
an actionable hint. Only allowlisted Google error/status codes are retained in the error
result; provider messages, quota metadata, request objects, exception text, prompts, and
credentials are never printed. The database stores failure state/timestamps, not raw error
payloads; discarded details from older attempts cannot be recovered retrospectively.

For example, `provider: HTTP 429 (resource_exhausted)` means Google rejected the request
for quota/rate limits. Check API billing and this model's quota for the project associated
with the AI Studio key; Gemini consumer-app subscriptions do not establish API billing.
Other categories distinguish key restrictions, missing keys, unavailable models, DNS/TLS,
timeouts, unsupported formats, malformed inline data, bad base64, byte-size excess, MIME
mismatches, invalid image contents, and local storage/publication failures.

The previous image remains active on failure. Do not delete/reset the reservation database
to bypass a cooldown: a timed-out/interrupted request may have been billed. Fix the issue
and wait until the next eligible startup, or make a fresh explicitly confirmed Scenes
request after a failed/successful outcome. Unconfirmed attempts remain blocked from manual
requests to avoid overlap; do not reset their state just to retry. There is also an **internal operator-only**
`retry_failed_startup` Ash action for an explicitly authorized single diagnostic attempt;
it is never called by startup, a timer, or the browser. It only accepts a prior failed
state, requires the service actor, reserves a fresh timestamp/version before HTTP, and
leaves the normal cooldown/retry policy intact. It must not be invoked without the user's
explicit permission for another potentially billable request. It refuses successful or
still-`generating` attempts, including interrupted ones. A persisted `generating` state after a crash is not
permission to retry. Public background reads expose that reservation as `uncertain`,
not proof that preparation is currently active; the UI announces an unconfirmed outcome.
This also honestly describes an in-progress request before its outcome is known. The
persisted state/timestamp/version are unchanged. There is no automatic job recovery.

## Verification

Automated tests use fake keys, local PNG/JPEG fixtures, and fake transports, never real Google calls.
`mix check` includes Ash codegen drift and native Node hook tests. See
[development guidance](DEVELOPMENT.md) for scoped Sobelow false-positive annotations and gates.
