# LOVELACE stage storage coordination

## Scope and lock identity

Every stage storage root has one permanent, owner-only, fixed-name SQLite file:
`.stage-coordination.sqlite3`. The trusted configured directory is mode `0700`;
the file is mode `0600`. It contains no business data or application tables. An
empty SQLite database supports the exclusive transaction used for exclusion.
No main-database schema, reservation, version, timestamp or manifest is changed
merely to acquire this lock. Ash retains all business writes and policies.

**Never unlink, replace, truncate or rotate the sidecar while any process could
use that storage root.** Two different inodes would split the lock identity.
Keep it for the root's lifetime. Only remove an entire disposable/test root after
all its processes have stopped. Root relocation/restoration requires quiescing
all users of both old and new roots. The protocol assumes local filesystems with
SQLite's supported locking, one authoritative business database for the root,
and cooperative applications using this protocol; it does not defend against
another process with the owner's OS permissions deliberately replacing files.
Symlink/nonregular coordination files fail closed. Infrastructure bootstrap
creates the directory/file before exclusion; it never replaces an existing file.

Do not count the sidecar as an image. Catalog membership protects digest-named `.png` /
`.jpg` files without a total count cap. Cleanup never matches the sidecar (or SQLite journal names).
No remote coordination service, distributed Erlang or BEAM-local mutex is used.
Independent BEAMs and independently owned connections contend through SQLite's
OS-backed file locks on the same sidecar.

## Ownership and lifetime

`Coordination.with_lock/2` opens a **private direct Exqlite handle in the calling
process**, sets a 1000 ms SQLite busy-acquisition timeout, and executes
`BEGIN EXCLUSIVE`. A busy/unavailable/corrupt lock fails closed without executing
the callback. There are no automatic retries, leases, expiry timestamps, stale
owner tokens, timeout-based takeovers or independently running lock managers.
The busy timeout bounds acquisition, not the lifetime of an acquired lock.

Only that calling process ever holds the handle. The handle is used in `after`
to close/rollback after **all** callback work, so the compiler/GC must keep it live
throughout the callback. It is never sent to another process or exposed to the
callback. The exclusive transaction has no pool/DBConnection timeout and cannot
be revoked by the main Repo timing out, disconnecting, restarting or dying.
Publication/selection callbacks contain bounded local validation/storage/SQL work, never
provider HTTP. Orphan reconciliation scans local filenames and performs indexed catalog
membership checks, without materializing or validating the whole image catalog.
A slow or suspended live owner continues to exclude all other mutations; those
callers fail closed after bounded acquisition rather than stealing ownership.

On ordinary return/error the handle closes; aborts roll back the lock transaction.
Close failures emit a generic warning, never raw errors/paths. On owner-process
death the last NIF-resource reference becomes unreachable and its destructor
closes SQLite; there is no surviving Erlang callback that can resume deletion.
On whole-VM death the OS closes its descriptors. Resource destruction may lag a
process `DOWN`; fresh lock acquisition is the authority, not the `DOWN` message.

### Why not the main pooled write transaction?

The initial proposed no-op singleton `UPDATE id = id` was rejected during
implementation review. A DBConnection timeout/disconnect can release that SQLite
lock while its callback remains alive, paused between a manifest read and file
deletion. A fatal monitor/link does not eliminate the release-before-kill race.
Using `timeout: :infinity` alone does not address connection death. The private
sidecar handle removes independently revocable lock ownership altogether.

### Raw filesystem deletion is essential

Destructive cleanup uses the documented `:file.delete(path, [:raw])` API, not
`File.rm/1` / file-server deletion. A file-server request could outlive a killed
lock owner and execute after the private handle has been released. The raw API
executes deletion in the owner process's dirty I/O NIF. No cleanup deletion is
sent to a worker, Task, file server or other independently surviving process.

OTP's NIF contract says resource objects remain allocated until the last handle
term is collected, and that when a process dies during a dirty NIF,
**"Deallocation of certain internal resources, such as process heap and process
control block, is delayed until the dirty NIF has completed."** Consequently the
live handle on that heap cannot be collected/release its SQLite lock before a
raw deletion already in progress finishes. Killing before the raw call prevents
the call; killing during it cannot make a later publisher race its completion.

Reviewed sources (installed Exqlite **0.43.0**, preserved OTP **29.0.1** target):

- [Exqlite README](../deps/exqlite/README.md): direct API, dirty NIF execution,
  isolated statement ownership; no concurrent sharing of a mutable statement.
- [Exqlite direct API](../deps/exqlite/lib/exqlite/sqlite3.ex): `open/2`,
  `set_busy_timeout/2`, `execute/2`, `close/1`. No statements are retained here.
- [Installed NIF implementation](../deps/exqlite/c_src/sqlite3_nif.c):
  `exqlite_open` returns an Erlang resource and releases the native reference;
  `connection_type_destructor` calls `sqlite3_close_v2`; `exqlite_close` rolls
  back an open transaction. This private handle is never given to DBConnection.
- [OTP 29.0.1 NIF reference](https://github.com/erlang/otp/blob/OTP-29.0.1/erts/doc/references/erl_nif.md):
  resource-object lifetime and dirty-NIF process termination/heap retention.
- [OTP 29.0.1 file API](https://github.com/erlang/otp/blob/OTP-29.0.1/lib/kernel/src/file.erl):
  `delete/2` with `raw` calls `prim_file:delete` in the calling process.
- [OTP 29.0.1 prim_file](https://github.com/erlang/otp/blob/OTP-29.0.1/erts/preloaded/src/prim_file.erl)
  and [native implementation](https://github.com/erlang/otp/blob/OTP-29.0.1/erts/emulator/nifs/common/prim_file_nif.c):
  `del_file_nif` is registered `ERL_NIF_DIRTY_JOB_IO_BOUND` and performs unlink.

Review these contracts on dependency/runtime changes. Preserve the private
resource and same-process raw deletion; monitors are not a replacement.

## Publication and cleanup ordering

1. Startup admission only reserves durable intent and its ID-only submission job.
   The protected Oban recovery worker reads existing state and attempts graceful orphan
   reconciliation. Reconciliation failure never resets or bypasses cooldowns; provider
   calls remain outside storage exclusion.
2. Ash's optimistic reservation commits **before HTTP**. HTTP holds neither the
   sidecar nor a main-database transaction and performs no automatic retry.
3. On provider success, `Storage.store_and_publish/4` takes the sidecar lock and
   opens a short main Repo transaction. It reads the current reservation inside
   exclusion and rejects a stale version/status **before writing any image**.
   It validates and atomically stores original bytes, upserts the Ash scene catalog and
   builds a bounded recent-fallback history, then invokes Ash's optimistic publication
   action in the same transaction. The catalog has no total count cap. That action
   remains authoritative; a conflicting reservation still makes publication fail.
4. The main publication transaction commits and the private sidecar handle closes.
   **Nothing is pruned in this transaction.** A failed/rolled-back publication
   leaves an orphan at worst, never deletion of files a rolled-back manifest needs.
5. The publication operation calls `Storage.prune/2` separately after publication returns committed.
   Cleanup reacquires the sidecar and checks the authoritative catalog **inside
   the lock**. Its caller's recent list is compatibility-only and ignored. Published
   scenes are never evicted; a delayed cleanup cannot delete an older or newer catalog
   image merely because it is absent from a recent-fallback list.

`Storage.store/2` keeps its public result contract and uses the same exclusion
protocol. Standalone store is not a promise of later publication protection: an
unregistered file can be reclaimed once the standalone call releases the lock.
Production publication must use the combined store-and-publish operation. There
is no unsafe public unlocked storage API.

`Storage.reconcile/3` also ignores supplied history and checks catalog authority inside
the same lock, preserving five minutes of unreferenced-image and UUID-temp grace.
Post-publication cleanup uses the same five-minute grace for unpublished orphan images
and interrupted temp writes. A live combined store/publication is protected by exclusion,
including repeated identical digests. Unknown files and nonregular
paths are left alone; substantive listing/stat/unlink errors are returned, not
silently discarded. Missing paths are harmless. An unavailable catalog fails closed.

Storage operations reject an existing main transaction or nested storage lock:
cleanup must never observe tentative publication or run before the caller's COMMIT.
Readers remain lock-free and revalidate membership, bytes, format and digest; a
missing or damaged file can yield a safe unavailable/fallback response, never remote
content or invalid bytes. Startup reports cleanup failures without undoing a
committed publication or marking it as a failed generation/retrying a paid call.

## Regression evidence

`test/lovelace/stage_designer/coordination_test.exs` is synchronous and uses
`test/support/disposable_stage_repo.ex`: two independently owned, non-sandbox,
one-connection dynamic Repos share each freshly migrated disposable SQLite file.
The resource's configured Repo routes through `put_dynamic_repo/1`. Every spawned
process selects its Repo explicitly. These tests never read the user's databases.

Deterministic message/telemetry barriers cover A-publish/B-publish/A-cleanup,
stale reconciliation and grace, in-flight/identical digest writes, preserved older catalog
images, tentative publication rollback, killed publication
owners, stale reservation rejection before storage, main-connection death, actual
DBConnection timeout notification while the private lock stays live, killed private
owners immediately before a destructive raw call, raw deletion execution in the
owning process, private/stable sidecar identity, and safe cleanup diagnostics.
Handlers and processes are cleaned up. The dirty-NIF in-progress lifetime itself
is established from OTP's contract/source, not claimed as an injected native unlink
stall in the test suite.

A separate disposable production-release smoke also held exclusion in one BEAM:
a second release BEAM failed bounded acquisition while it was held, then acquired
successfully after release. Both had generation disabled, HTTP/distribution off,
and synthetic disposable state/storage. This confirms cross-BEAM lock contention,
not a second execution of the complete publication interleaving.

G8 pauses a fake provider plug in the Interactions client's bounded transport helper
Task, reads the reserved row through the independent Repo, and acquires/releases the
sidecar through that Repo before allowing the response. This proves independent committed
reservation visibility and absence of storage exclusion spanning fake HTTP. The sidecar
probe is not an independent main-database writer test; no main Repo transaction spans
HTTP in the admitted scenery worker. The helper only bounds one owned request; startup
and recovery orchestration do not use application Tasks.
