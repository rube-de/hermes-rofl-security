#!/usr/bin/env bash
# Exit non-zero if the newest R2 snapshot is older than MAX_AGE_HOURS.
#
# The in-enclave watchdog covers "machine up, backups not happening". It cannot
# cover "machine gone" -- nothing running on the machine can. This is the check
# that notices that, so run it somewhere the machine isn't.
#
#   just backup-check          # default 3h
#   MAX_AGE_HOURS=6 just backup-check
#
# For a cron/launchd job, note it prints to stdout and signals via exit status:
#   0 = fresh, 1 = stale, 2 = could not reach the repository (also worth alerting)
set -euo pipefail
cd "$(dirname "$0")/.."
MAX_AGE_HOURS="${MAX_AGE_HOURS:-3}"

if ! json=$(./scripts/restic-run.sh snapshots --host rofl --json 2>&1); then
  echo "UNREACHABLE: cannot read the repository" >&2
  echo "$json" | tail -3 >&2
  exit 2
fi

read -r age_min newest < <(printf '%s' "$json" | python3 -c '
import json, sys, datetime
snaps = json.load(sys.stdin)
if not snaps:
    print("999999 none"); raise SystemExit
t = max(s["time"][:19] for s in snaps)
dt = datetime.datetime.fromisoformat(t).replace(tzinfo=datetime.timezone.utc)
age = (datetime.datetime.now(datetime.timezone.utc) - dt).total_seconds() / 60
print(f"{int(age)} {t}Z")
')

limit=$(( MAX_AGE_HOURS * 60 ))
if [ "$age_min" -gt "$limit" ]; then
  echo "STALE: newest snapshot $newest is ${age_min}m old (limit ${limit}m)"
  exit 1
fi
echo "OK: newest snapshot $newest, ${age_min}m old (limit ${limit}m)"
