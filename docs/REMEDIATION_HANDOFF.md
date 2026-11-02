# LOVELACE — review remediation handoff

## Status and scope

**All tasks below are outstanding. This handoff does not implement fixes.**

Eight focused reviewers assessed the current application tree after the reviewer
skills were created. The final cross-file review rejected acceptance for three
confirmed HIGH findings. The test reviewer separately rejected regression
protection; the cross-file reviewer classified those gaps as advisory because the
production guards exist. Address all listed regression gaps regardless of that
severity distinction.

The reviewed application baseline is commit `bbc0750` (`Add Gemini stage generation
and idle scenery mode`), plus the new reviewer skills/documentation. Review was
current-state, not a diff-only assessment. No application source, runtime targets,
dependencies, schema or private data was changed during review or handoff creation.
This document and the reviewer suite can be committed without implying remediation
is complete. Mark tasks complete only with implementation, discriminating tests
and fresh verification evidence.

Read `AGENTS.md`, all of [HANDOFF.md](HANDOFF.md),
[DEVELOPMENT.md](DEVELOPMENT.md), [STAGE_DESIGNER.md](STAGE_DESIGNER.md), and the
relevant local guidance linked from `DEPENDENCY_RULES.md` before implementing.
[REVIEWERS.md](REVIEWERS.md) describes the eight reviewers and how to invoke them.
Paths and line numbers below refer to the reviewed tree and will move as fixes land.

### Boundaries that must survive remediation

- Keep listeners loopback, Tidewave dev-only, and `.tool-versions` unchanged.
- Preserve Ash domain/action/policy ownership. No parallel Ecto business context,
  PostgreSQL, Redis or speculative durable-job infrastructure.
- Preserve server-only credentials, fixed production provider host, bounded request
  bytes/time, redirects off, and no automatic HTTP/task retries for generation.
- Preserve reservation committed before HTTP, minimum 24-hour attempt cooldown
  after failure/crash/unknown outcomes, previous-image/SVG fallback, default seven
  distinct retained images (configured range 1–7), and safe orphan reconciliation.
- The operator-only failed-attempt diagnostic action remains a separate, explicitly
  user-consented single potentially billable attempt. Never invoke it for this work.
- Do not restart the user's server, change private settings, reset reservations or
  inspect `.env`, `.env.keys`, real databases/sidecars, mail or generated imagery.
  Use synthetic fixtures, disposable storage/databases and fake provider responses.
- Maintenance commands must force `LOVELACE_STAGE_ENABLED=false`; do not inject
  real keys. Database/ConnCase/LiveView tests remain synchronous.
- Gmail/accounts/projects/OAuth/owner login/jobs remain deferred. App-wide scenery
  and its PubSub topic are intentional, not account-isolation defects.

## Confirmed high-priority findings

### F1 — Credential-bearing transport telemetry

- [ ] Implement a transport boundary that cannot emit credentials or raw provider
  request/response contents into telemetry.
- [ ] Complete G1 below at the real instrumentation seam.

**Evidence:** `lib/lovelace/stage_designer/gemini.ex:95–110` supplies the API key in
`x-goog-api-key` and the prompt as JSON to Req. The installed adapter builds a
Finch request unchanged (`deps/req/lib/req/finch.ex:191–232`). Finch's request span
emits the request and eventual result (`deps/finch/lib/finch.ex:615–619,843`;
`deps/finch/lib/finch/telemetry.ex:249–271,294–300`). Returned-error allowlists and
Logger redaction happen too late to prevent these events.

**Confirmed impact:** the key and prompt enter in-process telemetry metadata.
**No external export, persisted credential leak or credential compromise was
established.** The explicit project boundary still prohibits this emission.

**Safe reproduction already performed:** in a separate `mix run --no-start` BEAM,
attach to `[:finch, :request, :start]`, construct a synthetic request, and call the
streaming path with an absent Finch pool. The event contains the synthetic key
and body before pool lookup fails, without opening a connection. Only boolean
results were printed; LOVELACE was not started and no real key was read.

**Implementation direction:** inspect supported Req/Finch facilities and every
relevant emission path before choosing a solution. If the installed transport has
no supported sensitive-metadata control, use a reviewed compatible transport
boundary or dependency-level solution, retaining Req's required behavior and the
fixed production host. Document any dependency change and commit its lockfile.
Do not invent a `telemetry: false` option, edit ignored `deps/` as the lasting fix,
merely customize `Inspect`, attach a downstream redactor, or globally detach
unrelated handlers. Handler ordering and immutable event values make downstream
redaction insufficient. Do not weaken the no-secrets contract because telemetry
currently stays in-process.

**Acceptance:** synthetic keys, prompts, raw request structs, provider JSON/image
payloads and unsafe exception data never enter any relevant transport event;
useful safe timing/status diagnostics may remain. Verify success, streaming,
timeout/error and exception paths, not only request-start or safe warning text.

### F2 — Stale post-publication pruning can delete newer imagery

- [ ] Coordinate destructive cleanup with authoritative publication across BEAMs.
- [ ] Complete G2 below, including reconciliation and crash/partial-failure paths.

**Evidence:** `lib/lovelace/stage_designer/startup.ex:81–84` publishes then calls
`Storage.prune(settings, history)` with the local manifest. In
`lib/lovelace/stage_designer/storage.ex:65,83–95`, pruning immediately removes
files absent from that list. The five-minute cutoff is used by reconciliation,
not post-publication pruning. SQL optimistic locking fences database updates,
not this subsequent filesystem deletion.

**Failing interleaving:** A commits manifest H_A and is suspended before pruning.
After the legitimate 24-hour cooldown, B in another BEAM sharing SQLite/storage
publishes H_B with a new image. A resumes and deletes B's image because it is not
in H_A. With retention configured to one, the only published image can disappear,
forcing SVG fallback. No automatic retry or cooldown bypass is needed.

**Safe reproduction already performed:** store two different valid synthetic PNGs
in a fresh temporary directory, then call prune with the earlier one-item list.
The newer file is deleted. The directory was removed. This verifies stale-list
pruning mechanics, not a complete cross-BEAM pause/resume test.

**Implementation direction:** choose and document a minimal cross-process
coordination/fencing design for storage, publication, pruning and reconciliation.
A fresh manifest read alone still has a read/delete race. A BEAM-local GenServer,
mutex, or publication version check alone does not coordinate separate BEAMs.
Protect both newly published files and in-flight files, including identical
content digests being republished. Make stale or expired cleanup ownership unable
to delete files. Retain safe crash recovery and orphan cleanup rather than solving
this by leaking files forever or suppressing all pruning failures.

Keep provider HTTP outside SQLite transactions. Any local critical section must
stay bounded and preserve Ash ownership; do not accidentally invalidate an active
reservation by repurposing its optimistic-lock version as an unrelated cleanup
counter. Existing record-path locking is intentional SQLite compatibility, not a
reason to force unsupported atomic expressions. Review all cleanup entry points,
not just `prune/2`, against the same coordination protocol.

**Acceptance:** obsolete cleanup cannot remove current-manifest or in-flight
images; a newer published image remains readable and served after older work
resumes; cleanup still enforces configured distinct retention and safely reclaims
old orphan/temp files. Crashes cannot grant permission for a paid retry.

### F3 — Topbar's vendored-asset records are incomplete

- [ ] Retain reviewed Topbar license/provenance/checksum records, or remove the
  dependency without breaking navigation-progress behavior.
- [ ] Add an integrity/license regression test if the dependency remains.

**Evidence:** `assets/js/app.js:10` imports `assets/vendor/topbar.js`. Its header
identifies Topbar 3.0.0, MIT, an upstream URL and copyright, but no accompanying
complete MIT permission notice or recorded approved digest was found. Current
`test/lovelace_web/vendor_assets_test.exs` pins GSAP only. This violates the
mandatory asset contract in `AGENTS.md`; it is **not** evidence of malicious bytes,
a CDN dependency or a known vulnerability.

**Implementation direction:** verify the precise upstream version/artifact and
license, retain the complete applicable notice and exact provenance, record a
cryptographic checksum of the actual vendored file, and pin it in a test. Do not
blindly label the current bytes approved just by hashing them, replace them from
a runtime CDN, or mislabel GSAP's custom license as MIT. Any deliberate upstream
asset retrieval is a development operation, not a provider-generation operation;
never introduce a runtime download. Preserve necessary notices in distribution.

**Acceptance:** source, version, license, provenance, checksum and bundled import
agree, with an intentional update procedure and a failing check on unexpected
vendor-byte changes. GSAP/font records and integrity checks continue to pass.

## Required regression work

Start with tests that reproduce the current defects or demonstrate the missing
discrimination. Add tests beside the existing suites, not a parallel verification
framework. Where practical, temporarily disable the specific guard in a disposable
worktree to prove the new assertion fails, then restore it; never leave weakened
production code or mutate the user's working database. Keep all data synthetic.

### G1 — Exercise transport telemetry, not only Req.Test

- [ ] Cover credential/prompt/request/result containment at the actual adapter's
  instrumentation seam, including start/stop/error/exception and streamed data.
- [ ] Verify safe diagnostic categories still work, with no raw error/provider data.

`test/lovelace/stage_designer/gemini_test.exs` currently uses Req.Test, which bypasses
the real Finch transport. Existing log-redaction tests cannot catch F1. Use only
synthetic credentials and a controlled fake transport; a disposable loopback-only
fake server is acceptable if needed. Never contact Google or make the production
host allowlist configurable from untrusted input merely to simplify a test.
Detach test handlers and terminate any fake processes on exit.

### G2 — Deterministic publication/cleanup interleavings

- [ ] Pause A after publication but before cleanup, publish B, resume A and assert
  B's file, manifest and serving path remain correct.
- [ ] Cover a current in-flight write, stale reconciliation, repeated identical
  digests, retention count one and normal retention/pruning.
- [ ] Exercise crash/abort/expired-ownership behavior for the chosen coordination
  design; no stale owner may continue deleting or publish missing files.

Use deterministic barriers/messages, not a 24-hour sleep. Inject approved test time
and synthetic requests. The ordinary one-connection sandbox may serialize away
or mask the cross-BEAM issue: explicitly establish independent ownership/process
behavior with disposable databases/storage when required. Keep the test module
synchronous and never use the real data directory. Preserve the five-minute
orphan/temp grace policy or document an equally safe reviewed replacement.

### G3 — Otherwise-valid oversized PNG/JPEG inputs

- [ ] Add valid synthetic images over each dimension limit and over the pixel cap.
- [ ] Protect encoded-byte limits with structurally valid oversized inputs or a
  test seam that discriminates the byte guard from unrelated format rejection.
- [ ] Establish that JPEG rejection happens before native decoding/allocation.

At `test/lovelace/stage_designer/image_test.exs:88–90`, oversized PNGs contain only
`<<0>>` scanline data. At `jpeg_test.exs:52–54,66–68`, the frame helper has no
valid entropy-coded pixels. They remain invalid when dimension checks disappear.
Use compressible, bounded fixtures that would otherwise validate, with matching
valid controls. Cover both axes around 8192/8193 and the 16-million-pixel limit;
current examples include 4001×4000. Ensure fixtures remain under unrelated limits
when testing one particular guard. Avoid introducing unbounded memory/time into
the suite. Merely asserting another generic `invalid_image` on malformed data
still does not prove early preflight protection.

### G4 — Valid wrong-hash replacement

- [ ] Publish image A, replace its digest-path bytes with different valid image B,
  and assert the hash check rejects the replacement.
- [ ] Check both background fallback selection and the image endpoint; include
  PNG/JPEG or mixed-format cases where the changed behavior needs them.

`startup_test.exs:241` writes `"corrupt"`, which fails format validation independently
of `Storage.read`'s hash check (`storage.ex:43`). The new fixture must pass ordinary
image validation, match the tested extension, and differ from the URL's digest.
An intact retained fallback must still be selected/served.

### G5 — Valid unregistered content-addressed file

- [ ] Store a valid correctly named/hash-matching file absent from the manifest.
- [ ] Confirm direct storage validation succeeds while the public image action
  and HTTP endpoint refuse it, including during orphan-cleanup grace.

The unknown digest in `startup_test.exs:297–312` has no corresponding valid file;
the symlink alternate is not a valid digest filename. Neither independently
protects membership at `lib/lovelace/stage_designer/read_image.ex:14`. Preserve
existing malformed-name, traversal and symlink tests too.

### G6 — Stale publication and failure actions

- [ ] Add synchronous Ash-action tests rejecting stale `publish` and `fail`, not
  only stale `reserve`.
- [ ] Assert the winning record's version, timestamps, status and history remain
  unchanged after each stale attempt.

`startup_test.exs:188–193` covers reservation only. The current production locks at
`lib/lovelace/stage_designer/state.ex:37,45` exist and were statically verified;
this is missing regression protection, not proof they currently permit stale
writes. Distinguish these database tests from F2's post-commit filesystem defect.

### G7 — Repeated identical successful output

- [ ] Generate A, B, then A again on eligible synthetic timestamps; verify unique
  history, newest-first ordering and correct fallback/file retention.
- [ ] Exercise the configured retention bound without duplicate entries evicting
  useful distinct history, including mixed PNG/JPEG history when applicable.

Current retention tests always produce different images. Protect `Enum.uniq`
behavior at `lib/lovelace/stage_designer/startup.ex:78`; do not assume the schema's
maximum array length enforces distinctness.

### G8 — Independent-connection reservation-commit evidence

- [ ] Add a bounded regression proving the reservation is visible from an
  independent database connection/process before the fake HTTP boundary proceeds.

This is a recommended hardening check from the Ash review, not an identified
production transaction defect. The assertion in `startup_test.exs:37–42` uses the
shared sandbox; visibility there alone does not prove an independent connection
can see a committed reservation. Use only a disposable database and explicit
ownership/cleanup; do not turn database test modules async or inspect the user's
SQLite files. Keep this separate from choosing or installing a job engine.

## Secondary follow-ups from the review

These were nonblocking, but preserve them rather than losing the findings:

- [ ] **A1 — Honest interrupted-attempt status.** `read_background.ex:16` forwards
  persisted `:generating` and `lib/lovelace_web/components/layouts.ex:87–88` announces
  active preparation even after startup returns cached with no task. Represent
  interrupted/uncertain state honestly, with regression coverage. Never reset the
  cooldown, blindly retry or treat stale `generating` as an eligible diagnostic retry.
- [ ] **A2 — Measure synchronous mount-time image decoding.** `HomeLive.mount/3`
  calls background selection, which invokes storage validation and full JPEG pixel
  evaluation. Profile with synthetic retained imagery before asserting a latency
  failure or changing caching/async boundaries; preserve validation and safe serving.
- [ ] **A3 — Reconcile operational chronology.** `STAGE_DESIGNER.md:56` still says
  the server was not restarted, while `HANDOFF.md` section 18 records restart and
  successful display. Label old operations historical; do not restart the server
  to make the prose true.

## Suggested delivery order and completion gate

1. Reproduce F1/F2 with discriminating fake-boundary/interleaving tests. Record the
   chosen transport and cross-process coordination designs before implementation.
2. Fix F1 and F2, with G1/G2/G6 and failure/crash regressions. Keep commits focused;
   review any new schema/dependency artifacts together with their owners.
3. Complete F3 and its vendor integrity/license test, independently if practical.
4. Complete G3–G5/G7 and the independent-connection evidence in G8. Address A1/A3
   in bounded follow-ups; measure before taking on A2 as an optimization project.
5. Run fresh checks, inspect the actual diff and request focused re-review, then
   a final cross-file review. Update this checklist and the main handoff with
   implementation paths/results; do not mark a task done based on a plan or test name.

```sh
LOVELACE_STAGE_ENABLED=false mix check
LOVELACE_STAGE_ENABLED=false mix audit
MIX_ENV=prod LOVELACE_STAGE_ENABLED=false mix compile --warnings-as-errors
```

`mix check` includes schema drift and assets; `mix audit` is online and Hex-scoped,
not a comprehensive vendored-JS/native audit. For dependency/schema changes, commit
`mix.lock`, migrations and snapshots as applicable and refresh dependency guidance
with `mix usage_rules.sync`. Verify empty/current-schema migration paths against
**disposable** databases when the design changes persistence. Native/release loading
and browser checks should be repeated when the relevant paths change; report
unrun checks without weakening the gate.

Re-review routing: security/privacy and integration reliability for F1/G1;
Ash/SQLite, integration reliability and test reliability for F2/G2/G6/G8;
security/privacy and architecture for F3; test reliability for all regression work;
LiveView/UI for A1 or mount behavior changes. Finish with the cross-file reviewer,
passing current target paths, a sanitized change baseline and actual check results.
Account isolation remains N/A unless account-bearing behavior is introduced.

### Verification baseline from the completed review

Before remediation, all of the following passed:

- `LOVELACE_STAGE_ENABLED=false mix check`: **86 ExUnit + 32 JavaScript tests**,
  format/compile/Credo/AshCredo/Sobelow/schema drift/assets.
- `LOVELACE_STAGE_ENABLED=false mix audit`: no vulnerabilities or retired packages.
- `MIX_ENV=prod LOVELACE_STAGE_ENABLED=false mix compile --warnings-as-errors`.
- `git diff --check`; no application-source changes during review.

Those green results do not refute F1/F2/F3 or prove the missing regressions exist.
Review used source inspection plus the two synthetic probes described above. No
real provider requests, mailbox actions, private-data inspection or application
restart occurred. Browser behavior, release-runtime/native loading, hosted CI and
live-provider behavior were not freshly verified. Use this as a baseline, not as
post-fix verification evidence.
