#!/usr/bin/env bash
#
# Smoke-test the Cloudflare R2 + restic repository the ROFL sidecars use.
#
# Runs locally with the SAME pinned restic image and env mapping as the
# restic-restore / restic-backup services in the compose files, so a pass here
# means those sidecars will boot and back up on ROFL. Run before `just ship`.
#
# Usage:
#   just test-r2              # full check incl. backup/restore round-trip
#   just test-r2 --read-only  # connectivity + integrity only, no writes
#
# Reads the same secrets the sidecars consume, from .env (or the ambient
# environment when invoked via `just`, which dotenv-loads):
#   R2_ACCOUNT_ID  R2_BUCKET  R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY
#   RESTIC_PASSWORD   (raw — NOT obscured, unlike the RCLONE_CRYPT_* pair)
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/_restic-common.sh
. "$SCRIPT_DIR/_restic-common.sh"

READ_ONLY=0
[ "${1:-}" = "--read-only" ] && READ_ONLY=1

step "Preflight"
restic_preflight
ok "all five R2/restic secrets present"
ok "bucket: $R2_BUCKET   endpoint: $R2_ENDPOINT"

# --- 1. repository reachable --------------------------------------------------
# This is exactly the guard restic-restore runs at boot. It exits non-zero for
# an absent repository, wrong credentials and network failure alike, and exits 0
# printing "[]" only for a reachable-but-empty repository — so a failure here
# can never be misread as "nothing to restore".
step "1/4  Repository reachable (endpoint + credentials + password)"
if ! snaps=$(restic snapshots --host "$RESTIC_HOST" --json 2>&1); then
  printf '%s\n' "$snaps" | sed 's/^/    /' >&2
  fail "$(restic_explain "$snaps")"
fi

if [ "$(printf '%s' "$snaps" | tr -d '[:space:]')" = "[]" ]; then
  ok "repository opens, and is EMPTY (a first deployment would restore nothing)"
else
  ok "repository opens: $(printf '%s' "$snaps" | grep -o '"short_id"' | grep -c .) snapshot(s) for host '$RESTIC_HOST'"
  latest=$(restic snapshots --host "$RESTIC_HOST" --latest 1 2>/dev/null | grep -E '^[0-9a-f]{8} ' | tail -1 || true)
  [ -n "$latest" ] && ok "latest: $latest"
fi

# --- 2. retention identity ----------------------------------------------------
# Snapshots are grouped for retention by (host, paths). If anything ever wrote
# under a different host, `restic forget` silently keeps everything and still
# exits 0 — the failure mode is unbounded storage growth with no error at all.
step "2/4  Retention identity (all snapshots under one pinned host)"
# r2-conntest is excluded: step 4 writes a probe snapshot under that host and
# removes it again. If that removal ever fails, this check would otherwise send
# you chasing a test artefact that is deliberately outside the retention group.
hosts=$(restic snapshots --json 2>/dev/null | tr ',' '\n' \
        | grep -o '"hostname":"[^"]*"' | sed 's/.*:"//;s/"//' \
        | grep -v '^r2-conntest$' | sort -u || true)
if [ -z "$hosts" ]; then
  ok "no snapshots yet — nothing to group"
elif [ "$hosts" = "$RESTIC_HOST" ]; then
  ok "single host '$hosts' — retention will apply correctly"
else
  warn "more than one host present: $(printf '%s' "$hosts" | tr '\n' ' ')"
  warn "'restic forget' groups by host, so each group is kept in full and"
  warn "retention effectively stops working. Consolidate before relying on it."
fi

# --- 3. integrity -------------------------------------------------------------
step "3/4  Repository integrity (structure + index)"
if out=$(restic check 2>&1); then
  ok "restic check passed"
else
  printf '%s\n' "$out" | tail -5 | sed 's/^/    /' >&2
  fail "restic check reported problems — do not rely on this repository until resolved"
fi

# --- 4. write round-trip ------------------------------------------------------
if [ "$READ_ONLY" -eq 1 ]; then
  step "4/4  Write round-trip — SKIPPED (--read-only)"
  printf '\n\033[32mR2 connection OK\033[0m (read-only checks passed)\n'
  exit 0
fi

step "4/4  Backup round-trip (write → restore → verify → forget)"
# A dedicated host keeps the probe out of the real retention group entirely, so
# a probe snapshot can never influence what `restic forget --host rofl` keeps.
PROBE_HOST="r2-conntest"
payload="r2 round-trip probe $(date -u +%FT%TZ) host=$(hostname) pid=$$"

if ! out=$(resticsh "
    set -e
    mkdir -p /tmp/probe /tmp/verify
    printf '%s' '$payload' > /tmp/probe/probe.txt
    restic backup /tmp/probe --host '$PROBE_HOST' --tag conntest --quiet
    restic restore latest --host '$PROBE_HOST' --target /tmp/verify --quiet
    cat /tmp/verify/tmp/probe/probe.txt
  " 2>&1); then
  printf '%s\n' "$out" | tail -5 | sed 's/^/    /' >&2
  fail "backup round-trip failed — these credentials can apparently read but not write"
fi

[ "$(printf '%s' "$out" | tail -1)" = "$payload" ] \
  || fail "restored content does not match what was written"
ok "wrote a snapshot, restored it, and the content matches"

# Remove the probe snapshot BY ID. `--keep-last 0` does not work: restic reads 0
# as "unset" and refuses with "no policy was specified". The alternative,
# --unsafe-allow-remove-all, deletes everything the filters match — one wrong
# filter and it takes real snapshots with it. Explicit IDs cannot do that.
#
# No --prune: that takes an exclusive repository lock and would contend with a
# backup running on ROFL. The few KiB left behind are reclaimed by the
# sidecar's next scheduled prune.
probe_ids=$(restic snapshots --host "$PROBE_HOST" --tag conntest --json 2>/dev/null \
            | grep -o '"short_id":"[^"]*"' | sed 's/.*:"//;s/"//' | tr '\n' ' ')
if [ -z "$probe_ids" ]; then
  warn "probe snapshot not found to remove — check 'just restic snapshots'"
# shellcheck disable=SC2086
elif restic forget $probe_ids >/dev/null 2>&1; then
  ok "probe snapshot removed"
else
  warn "could not remove the probe snapshot — remove it with:"
  warn "  just restic forget $probe_ids"
fi

printf '\n\033[32mR2 connection OK\033[0m — restore + backup sidecars will work with these secrets\n'
