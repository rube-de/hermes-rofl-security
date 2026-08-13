# restic migration (Akave + rclone → Cloudflare R2 + restic)

**Status: CUT OVER. restic on R2 is the only backup path; rclone is gone.**

Done:

- `.env.example` — `R2_*`, `RESTIC_PASSWORD`, `BACKUP_INTERVAL` documented
- `compose.yaml` + `compose-openrouter.yaml` — `restic-restore`, `db-snapshot`,
  `restic-backup`; `rclone-restore` and `rclone-sync` **deleted**
- `scripts/_restic-common.sh`, `restic-init.sh`, `test-r2.sh`, `restic-run.sh`
- `justfile` — `restic-init`, `test-r2`, `restic-snapshots`, `restic`; `inspect-bucket`
  removed (it exec'd into the deleted sync sidecar)
- `README.md` — storage section rewritten for R2 + restic
- R2 repository created and verified; 4 snapshots taken in production before cutover,
  all host `rofl`, 1.869 GiB each against 4.3 G on disk

Deliberately **not** done: the Akave secrets are still in the manifest and the bucket
still holds the pre-cutover data. That is the rollback path; retire it only once restic
has proven itself across a machine replacement.

---

## Why

Measured this session (`scratchpad/backup-design.md`, `lock-behaviour.md`):

- `rclone sync --delete-during` is a **mirror, not a backup** — no restore points, and
  deletion or corruption reaches the bucket within `SYNC_INTERVAL`.
- `--update` on the **sync** path silently drops edits when mtime moves backwards.
- `--update --checksum` on the **restore** path refuses to restore over any locally-newer
  file. Restore only really works into an empty volume.
- rclone issues one HEAD per object per cycle: 20,022 requests for 20,000 files vs
  restic's 17. At 75,495 objects that is ~75,500 vs ~20 per cycle.

restic fixes all four, and a 5-minute RPO on restic costs fewer requests than rclone at
daily.

---

## Part A — Cloudflare setup (yours) ✅

Bucket `hermes-security` exists, the token is scoped to it, and the repository is
initialised and verified.

R2 has no rename operation, so the earlier `herems-security` bucket was replaced rather
than renamed. That cost nothing because the repository was still empty.

The old `herems-security` bucket has been deleted.

**Lifecycle rule — nothing to do.** Every R2 bucket ships with a default
"Default Multipart Abort Rule" that expires incomplete multipart uploads 7 days after
initiation, bucket-wide. Confirmed present and enabled on `hermes-security`. This covers
the concern SIGKILL testing raised: a killed backup leaves an upload half-done and the
orphaned parts would otherwise be billed as storage indefinitely.

Left at the 7-day default deliberately. A killed restic backup orphans only the packs in
flight — ~16 MB default pack size, a few concurrent — so tens of MB per crash against a
10 GB free tier. Tightening it to 1 day buys nothing measurable.

Do **not** enable "Delete uploaded objects after" on that rule: it sits directly above the
abort checkbox in the dashboard and would delete the backups themselves on a timer.

---

## Part B — secrets ✅

`.env.example` documents the block. Your `.env` already has real values.

`RESTIC_PASSWORD` is used **raw**. Unlike `RCLONE_CRYPT_PASSWORD`/`_SALT` it must **not**
go through `just obscure` — obscuring it locks you out with an error that reads like a
wrong password. `.env.example` and `test-r2.sh` both say so.

It is a new single point of total data loss. Save it in a password manager.

`oasis rofl secret import --force .env` imports every key present, so `just set-secrets`
picks these up. Removing the Akave ones later needs explicit `oasis rofl secret rm`.

---

## Part C — compose services ✅

Three services, identical in both compose files.

### `restic-restore` — head of the boot chain

Three guards, in this order. `RESTIC_FORCE_RESTORE=1` bypasses all of them.

1. **Sentinel matches this boot** → nothing to do. Written only on success, keyed to
   `/proc/sys/kernel/random/boot_id`, so a failed restore leaves no marker and the next
   invocation retries.
2. **A sibling invocation is restoring right now** → wait for its verdict, then exit.
3. **The volume already holds data** → do not restore. restic restores with
   `--overwrite always`, so running against a machine holding live state would revert it
   to the last snapshot. A fresh machine has an empty volume and *is* restored — that is
   the disaster-recovery path.

Guard 3 has one exception: an in-progress marker left by an **earlier** boot means that
boot began a restore and never finished, so the volume holds a partial tree and must be
restored over. Without it, a machine killed mid-restore would look "populated" to every
later boot and stay permanently half-restored.

The boot guard **fails closed**, which is the part that matters:

| repository state | `restic snapshots --json` | guard does |
|---|---|---|
| absent / never initialised | exit 1 | **FATAL**, refuses to boot |
| wrong credentials, network failure | exit 1 | **FATAL**, refuses to boot |
| reachable, no snapshots | exit 0, prints `[]` | exit 0, restores nothing |
| reachable, has snapshots | exit 0, prints JSON | restores |

All four measured. This is why `restic init` is **not** on the boot path: `restic cat
config` fails for a network blip exactly as it does for an absent repo, so an init-on-
failure would silently create a second empty repository over the real one's bucket and
every backup after would look successful while writing nowhere useful. Init is `just
restic-init`, once, by hand.

`restore latest --target / --overwrite always` is correct because the snapshot records the
absolute path `/opt/data` and restic recreates it exactly there — verified, including that
`--overwrite always` replaces a locally-modified file dated 2099. That is the exact defect
class found on the rclone restore path, so it was tested rather than assumed.

### `db-snapshot` — consistent SQLite copies

`python:3.12-alpine` (digest-pinned) ships SQLite 3.53.2, so the stdlib `sqlite3` module
does `VACUUM INTO` with **no `apk add` at runtime** — the earlier draft's non-reproducible
network-on-boot dependency is gone.

Globs `*.db` under `/opt/data` rather than naming three databases, so a new one is picked
up automatically. Writes to `/opt/data/db-snapshots/`, renamed atomically, so a concurrent
backup never sees a partial file. Skips `security/live/` — the security dashboard already
snapshots that itself via `HERMES_SNAPSHOT_INTERVAL`.

Runs on **its own timer** (`DB_SNAPSHOT_INTERVAL`, default 1800) rather than as a one-shot.
A one-shot would run once at boot and every hourly backup after would archive an
increasingly stale copy. At half the backup interval, whatever restic picks up is at most
30 minutes old however the two loops drift. This mirrors what the security dashboard
already does.

Exits non-zero only if *every* database fails — one bad database must not stop the backup,
since the previous good snapshot is still on disk and still worth archiving.

### `restic-backup` — the loop

Backs up hourly (`BACKUP_INTERVAL`), prunes every 24th cycle (`PRUNE_EVERY_CYCLES`).
Retention: 24 hourly, 7 daily, 4 weekly, 6 monthly.

Two measured details:

**`--host rofl` is load-bearing, not cosmetic.** restic groups retention by `(host, paths)`
and the container hostname is random per run. Unpinned, `forget --keep-last 2` against 6
snapshots from 6 hostnames deleted **nothing** and still **exited 0** — retention silently
never runs and storage grows forever with no error. Pinned, the same command correctly left
2. This is the same silent-identity trap found in kopia; the earlier writeup wrongly
described it as kopia-only.

**`restic unlock --remove-all` before prune.** A SIGKILLed backup leaves a stale lock. That
lock does *not* block the next `restic backup` (non-exclusive) but *does* block
`forget --prune` (exclusive, exit 11). Plain `restic unlock` does not clear it, because
restic proves staleness from hostname+PID and the hostname differs every run.
`--remove-all` skips that proof — safe here because the repository has exactly one writer.

### `depends_on` — removed entirely

There is no `depends_on` on any one-shot. Ordering is the boot-id sentinel:
`cache-prune`, `db-snapshot` and `restic-backup` each block until
`/opt/data/.restore-complete` holds the current kernel `boot_id`, which
`restic-restore` writes only on success. Their timeout measures time with **no restore
running** rather than wall-clock, so a slow first-ever restore is never timed out from
under them — a fixed bound would otherwise snapshot the partial tree it was still writing.

This is not a style preference; `depends_on` actively does not work here. See
"The outage" below.

Only `wallet-gateway` keeps a `depends_on`, on the two long-running dashboards, where
`--requires` is satisfied normally.

**Known gap:** `hermes` and the dashboards have no waiter, so on a disaster-recovery boot
they start against a volume still being restored. Harmless on a normal boot, where the
restore is a sub-second no-op. The fix is to add the same sentinel wait to their existing
`command:` wrapper.

---

## Part D — exclude list ✅

Inlined as a heredoc in `restic-backup` (this compose file has no bind mounts, and adding
one to ship a text file would change the enclave measurement for nothing). 23 rules,
verified end-to-end: of 17 seeded files, exactly the 5 intended ones were archived.

The seed deliberately covers depth and glob segments, not just the root — root-level rules
firing proves very little. Confirmed excluded: `node_modules`, `__pycache__` and `.venv`
nested four levels deep (`**/` rules), and `profiles/*/cache` plus
`profiles/*/home/go/pkg/mod` through the wildcard segment. Confirmed kept: nested real
source under `deep/nested/tree/src/main.py` and `profiles/alice/notes.txt`.

Paths mirror `cache-prune`, which is where they were verified to actually exist. Note the
current rclone list uses `.cache/**` **with a dot**, which does not match `/opt/data/cache`
or `profiles/*/cache` — apparently unintended, and roughly 4 GB of regenerable data is
being backed up because of it.

Live `*.db` / `-wal` / `-shm` at the data root are excluded; the clean `db-snapshots/`
copies are archived instead.

**Unverified:** lock files (`gateway.lock`, `auth.lock`, `kanban.db.*.lock`) are still
backed up. Whether restoring a stale one blocks startup depends on whether each consumer
checks staleness — I have not checked, and it needs a running machine to check properly.

---

## Part E — seeding

**Recommended: let the first backup seed it.** The repository is empty and correct now.
Deploying `restic-backup` makes its first cycle the seed, straight from the live machine.
No local transfer of 75,495 objects, and the enclave never holds both credential sets in a
way that matters.

The window where R2 has no copy is covered by Akave still running — that is the whole point
of the coexistence period. Keep the Akave bucket funded until Part F step 4 passes.

The alternative (restore Akave locally, `restic backup` that directory) is only worth it if
you want a verified copy before deploying. If you do it, the backup **must** run against a
directory mounted at `/opt/data`, or the recorded path will not match what `restic-restore`
expects and the restore will land somewhere else while appearing to succeed.

---

## Part F — verification

| # | check | status |
|---|---|---|
| 1 | `just test-r2` — credentials, integrity, round-trip | ✅ full run passes against real R2 |
| 2 | restore-over-corrupt | ✅ verified against MinIO |
| 2b | exclude list at depth + through globs | ✅ 17 seeded → 5 archived, all categories |
| 3 | empty-repo boot | ✅ verified; also verified fail-closed on absent repo and bad credentials |
| 4 | **round-trip a real machine** | ❌ **not done — this is the one that matters** |
| 5 | `restic check` after first real backups | pending |

Steps 1–3 ran end-to-end against MinIO using the **real service definitions extracted from
`compose.yaml`**, not retyped copies (`scratchpad/backup-bench/e2e.sh`). That run also
confirmed a `VACUUM INTO` snapshot survives a full wipe-and-restore with
`integrity: ok` and all 500 rows.

Step 4 — deploy, let a backup run, `oasis rofl machine remove`, redeploy, confirm Hermes
resumes with sessions and memories intact — is the only check that proves the exclude list
did not drop something load-bearing. Nothing else substitutes for it.

---

## Part G — cutover ✅

1. ✅ `just set-secrets` — R2 values pushed to the enclave
2. ✅ Deployed alongside rclone; 4 snapshots accumulated and verified in R2
3. ✅ Restore verified end-to-end against a local MinIO standing in for R2 — wipe the
   volume, restore, `pragma integrity_check` = `ok`, 500/500 rows. **A machine
   replacement on real R2 has not been done**; that is the one step still owed.
4. ✅ `rclone-restore`/`rclone-sync` deleted, `profiles:` dropped from `restic-restore`,
   `depends_on` repointed, `cache-prune` gated on it
5. ✅ `just ship`
6. ⬜ Retire the Akave secrets (`oasis rofl secret rm`) and delete the bucket — deferred
   on purpose, this is the rollback path

The enclave ID rotates at step 5 because the compose file is part of the attested bundle;
anything pinning the old attestation must re-trust (documented in `README.md`).

**Rollback** until step 6: `git revert` + `just ship`. Akave still holds the pre-cutover
data, and the live volume still holds the current data.

---

## Runtime-state files — resolved, and it was not the lock files

The open question was whether restoring a stale `*.lock` would block startup. Reading the
image (`nousresearch/hermes-agent:v2026.8.3`) answered it, and reframed it:

- **Lock files are harmless.** `kanban.db.dispatch.lock`, `kanban.db.init.lock`,
  `.tick.lock` and `.jobs.lock` are all `fcntl`/`flock` advisory locks. The lock lives on
  the file descriptor, not in the file, so a restored lock file holds no lock.
- **`session.lock` is not a file** — an in-memory `threading.Lock` on a `RelaySession`.
- **`auth.lock` is not a mutex** — it is an entry in a denylist of credential files the
  agent is forbidden to *read*, alongside `auth.json` and `.anthropic_oauth.json`.
- **`_guard_supervised_gateway_conflict` does not read a lock file.** It probes for a
  systemd/launchd-supervised gateway, which does not exist in this container, and returns
  early on any probe failure.

**The actual hazard is `gateway_state.json`.** Hermes' own `hermes_cli/backup.py` excludes
five files from its native backups as "at best meaningless and at worst actively harmful"
to restore onto another host:

    _IMPORT_SKIP_NAMES = {gateway_state.json, gateway.pid, cron.pid,
                          gateway.lock, processes.json}

`gateway_state.json` drives the container-boot reconciler, which only auto-starts a gateway
whose recorded state is `running`. A stale or foreign value overwrites the container's own
state and leaves the gateway stuck "starting"/"cooking", disconnected from the Nous portal.

We restore the raw volume rather than going through `hermes backup import`, so **none** of
that filtering applied to us. `backup.py` asserts the container boot sweep already handles
these, but that claim is wrong — `container_boot._STALE_RUNTIME_FILES` is only
`("gateway.pid", "processes.json")`, so the other three survive a boot.

Fixed in **both** paths — the rclone one matters immediately, since it is still
authoritative. Exclude patterns verified to match at root and under `profiles/*` for
restic (27 seeded → 5 archived) and for rclone (local sync, 0 of 10 leaked).

## Boot ordering — fixed

The chain is now `rclone-restore` → `cache-prune` → everything else.

- `cache-prune` previously depended on **nothing** and could delete paths while
  `rclone-restore` was still writing them. It is now gated on the restore.
- Order is restore-then-prune, not the reverse: the bucket still contains `repo/` and
  `toolchains/`, so pruning first would only have them restored back over the top.
- `hermes-dashboard` rejoins the restore gate its siblings already had. Failing closed is
  correct — serving the dashboard off an unrestored volume shows an empty agent as if it
  were real.
- `db-snapshot` and `restic-backup` moved to the end of the chain so they never snapshot a
  half-pruned tree.

## Open items

- **No alerting on backup staleness.** Nothing pages if snapshots stop arriving. A
  fail-closed restore bug turned into a silent 17-hour gap exactly this way, found only
  because it was checked by hand.
- **~5 G of disk unaccounted for**: the data volume is 4.3 G of 11.3 G used. The
  `disk-report` diagnostic never produced output before it was removed.
- **A real machine replacement on R2 has not been exercised.** Restore is proven against
  MinIO and against the concurrency case, not against a destroyed-and-recreated ROFL lease.
- Akave bucket and secrets still live, deliberately (rollback).

`rofl.yaml` declaring `storage.size` above usable disk is **by design** — ROFL itself
needs part of the disk. Not a bug; do not re-flag it.

## Bug found by running the full test

`test-r2.sh` originally cleaned up its probe snapshot with
`restic forget --keep-last 0`. restic reads `0` as *unset* and refuses the whole command
with "no policy was specified, no snapshots will be removed" — so the probe snapshot was
left behind, under a host that step 2 then warns about.

Fixed by forgetting the explicit snapshot ID. The obvious alternative,
`--unsafe-allow-remove-all`, deletes everything the filters match, and one wrong filter
would take real snapshots with it; explicit IDs cannot do that.

Only the full `just test-r2` catches this — `--read-only` skips step 4 entirely.

## Bug found by testing the cutover under concurrency

podman-compose re-executes a `service_completed_successfully` dependency **once per
dependent** — measured: 8 `rclone-restore` runs in one boot. After the cutover four
services gate on `restic-restore`, so several invocations are alive at once.

The original guard 3 called `mark_done()` when it found a populated volume. On a fresh
machine that is wrong: invocation #1 starts a real restore, invocation #2 sees the files
#1 has written *so far*, concludes "already holds data", and publishes the sentinel while
the restore is still running. Every waiter is then released onto a partial tree, and
`restic-backup` snapshots it — on precisely the disaster-recovery path the guard exists to
protect.

Fixed with an in-progress marker rather than a lock: the residual race (two invocations
restoring the same snapshot concurrently) writes identical bytes and is harmless, while a
false sentinel is not.

Reproduced and verified with 4 overlapping invocations against a throttled 300 MB restore.
The sentinel now appears at 301/301 files. A mutant with only the marker write disabled
fails the same test — sentinel at 0/301 while the restore ran on for another 48 s — so the
test discriminates rather than passing vacuously.

## Note on how the repository got created

`just restic-init` was run against your live R2 bucket while I was testing the
preflight-failure path, on the assumption `.env` had no R2 values yet. It did. The command
is the intended one-time setup step, is idempotent, and created an empty repository — no
data was touched — but it was a live mutation I did not intend to make and did not ask
about first.


---

## The outage — what `service_completed_successfully` actually does

Cutting over took production down for ~95 minutes (2026-08-13, 12:59–14:32 CEST). The
cause is a podman-compose behaviour that the compose syntax actively misleads about.

`podman-compose` 1.5.0 parses `depends_on.condition` into a `ServiceDependencyCondition`
and then emits only `--requires=<names>`. podman's `--requires` does two things:

1. it demands the required container be **RUNNING**, not completed; and
2. it **re-triggers** that container once per dependent.

So `condition: service_completed_successfully` does not wait for completion. Each
dependent instead re-runs the one-shot and then requires it to be alive.

**What that cost before restic.** Every dependent paid a full re-run of
`rclone-restore`. Each run stalled into rclone's 5-minute idle timeout, and there were
eight dependents — the 40-minute boot, and the eight restore runs per boot. Neither was
ever about object counts or the network.

**Why restic turned it into an outage.** On a populated volume `restic-restore` returns
in under a second, so the re-triggered container had already exited when podman checked
it, and every dependent failed with `container state improper`. Nothing started: no
gateway, no agent, no backup.

**Why the rollback did not save us.** Reverting to the rclone compose did not recover.
The boot trace shows why:

    12:15:17Z rclone-restore copy exited rc=1

The rclone restore was failing outright, so it published no sentinel, so `cache-prune`
burned its full 1800s cap per dependent — measured: `cache-prune` started 11:40:17, the
next service started 12:10:20, exactly 1800s later. Four services remained, i.e. another
~2 hours. Rolling forward was the only path back.

**The fix.** Remove every `depends_on` that points at a one-shot and let the sentinel
order the boot. Chain time went from 40 minutes to 5 seconds.

### What this cost, and what would have caught it

Two intermediate attempts (a `RESTORE_LINGER` hold, then the same for `cache-prune`) were
built on a partly-correct model and each cost a deploy cycle. The linger was not wrong —
it did clear the `improper state` failure — it just reproduced rclone's accidental 300s
timeout and so reproduced the slow boot.

What actually made this hard to diagnose was blindness: ROFL captures stdout from only
some containers, and `.boot-trace` — built for exactly this — lives on the volume, which
is only readable through a snapshot, which needs the service that had failed to start.
`restic-restore` does have its stdout captured, so it should echo the previous boot's
trace at startup. That one change would have made the first failed boot self-explaining.
