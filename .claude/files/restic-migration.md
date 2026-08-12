# restic migration (Akave + rclone → Cloudflare R2 + restic)

**Status: repo-side work implemented and tested; NOT cut over.**

Done:

- `.env.example` — `R2_*`, `RESTIC_PASSWORD`, `BACKUP_INTERVAL` documented
- `compose.yaml` + `compose-openrouter.yaml` — `restic-restore`, `db-snapshot`,
  `restic-backup` added **alongside** the rclone pair
- `scripts/_restic-common.sh`, `restic-init.sh`, `test-r2.sh`, `restic-run.sh`
- `justfile` — `restic-init`, `test-r2`, `restic-snapshots`, `restic`
- R2 repository created and verified (`just test-r2 --read-only` passes: opens, empty,
  `restic check` clean)

Not done, deliberately: the rclone services are still the authoritative backup path, and
nothing depends on the restic services. Cutover is Part G.

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

### `restic-restore` — behind `profiles: ["restore"]`

**Does not start on `docker compose up`.** While `rclone-restore` is still authoritative,
two restore services writing one volume would race. Run it deliberately:

```sh
docker compose run --rm restic-restore
```

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

### `depends_on`

`db-snapshot` and `restic-backup` gate on **`rclone-restore`**, the authoritative restore
path — not on `restic-restore`. Backing up a half-restored volume produces a valid-looking
snapshot of incomplete data, and after 24 cycles retention could age out the good snapshots
and leave only those. This dependency direction cannot delay `hermes`: nothing depends on
the restic services.

**Still open — pre-existing race, not introduced here:** `cache-prune` depends on nothing
and can delete paths while `rclone-restore` is writing them. Fix it at cutover by gating it
on the restore service. Once regenerable data is excluded from the backup this becomes
harmless, but it is live today.

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

## Part G — cutover (not started)

1. `just set-secrets` — push the R2 values to the enclave
2. Deploy with restic **alongside** rclone; let backups accumulate; run `just test-r2`
3. Do Part F step 4 — replace the machine, restore, verify
4. Only then: delete `rclone-restore`/`rclone-sync`, drop `profiles:` from
   `restic-restore`, repoint every `depends_on` at it, and gate `cache-prune` on it
5. `just ship`
6. Retire the Akave secrets (`oasis rofl secret rm`) and delete the bucket — last

The enclave ID rotates at step 5 because the compose file is part of the attested bundle;
anything pinning the old attestation must re-trust (documented in `README.md`). Adding the
restic services at step 2 also rotates it.

**Rollback** until step 6: `git revert` + `just ship`. Akave still holds the data.

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

- Regenerable data is still **in the rclone bucket** (`repo/`, `toolchains/`, the pnpm
  store): the live exclude list uses `.cache/**` with a dot, which does not match
  `/opt/data/cache` or `profiles/*/cache`. `just purge-bucket-cruft` exists for this. The
  restic exclude list already handles it, so this retires at cutover.
- `rofl.yaml` declares `resources.storage.size: 17000` while the machine showed 15.2 G
  usable — unrelated, still unexplained.

## Bug found by running the full test

`test-r2.sh` originally cleaned up its probe snapshot with
`restic forget --keep-last 0`. restic reads `0` as *unset* and refuses the whole command
with "no policy was specified, no snapshots will be removed" — so the probe snapshot was
left behind, under a host that step 2 then warns about.

Fixed by forgetting the explicit snapshot ID. The obvious alternative,
`--unsafe-allow-remove-all`, deletes everything the filters match, and one wrong filter
would take real snapshots with it; explicit IDs cannot do that.

Only the full `just test-r2` catches this — `--read-only` skips step 4 entirely.

## Note on how the repository got created

`just restic-init` was run against your live R2 bucket while I was testing the
preflight-failure path, on the assumption `.env` had no R2 values yet. It did. The command
is the intended one-time setup step, is idempotent, and created an empty repository — no
data was touched — but it was a live mutation I did not intend to make and did not ask
about first.
