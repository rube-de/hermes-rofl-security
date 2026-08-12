#!/usr/bin/env bash
#
# Create the restic repository on Cloudflare R2. ONE-TIME setup.
#
# Deliberately a manual step, and never done by the sidecars: `restic init` on a
# boot path would turn any transient error — a network blip, a wrong endpoint,
# an expired token — into a silently created second, empty repository beside the
# real one, and every backup after that would report success while writing
# nowhere useful. The compose guard therefore treats "no repository" as fatal.
#
# Usage:
#   just restic-init
#
# Safe to re-run: restic refuses to initialise over an existing repository.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/_restic-common.sh
. "$SCRIPT_DIR/_restic-common.sh"

step "Preflight"
restic_preflight
ok "target: s3:${R2_ENDPOINT}/${R2_BUCKET}"

step "Checking for an existing repository"
if restic cat config >/dev/null 2>&1; then
  ok "a repository already exists here — nothing to do"
  printf '\nRun \033[1mjust test-r2\033[0m to verify it end to end.\n'
  exit 0
fi

step "Initialising"
if ! out=$(restic init 2>&1); then
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  case "$out" in
    *"does not exist"*)
      fail "the bucket '${R2_BUCKET}' does not exist — create it in the Cloudflare R2 dashboard first" ;;
    *)
      fail "$(restic_explain "$out")" ;;
  esac
fi
printf '%s\n' "$out" | sed 's/^/    /'
ok "repository created"

cat <<'NOTE'

  IMPORTANT: save RESTIC_PASSWORD to a password manager now.
  It is the only key to this repository. There is no recovery path,
  no second factor, and no way to read a single byte back without it.

  Next:
    just test-r2      # verify connectivity, integrity and a round-trip
NOTE
