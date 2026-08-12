#!/usr/bin/env bash
#
# Run an arbitrary restic command against the R2 repository, using the same
# pinned image and credentials as the compose sidecars.
#
# Usage:
#   just restic snapshots
#   just restic ls latest
#   just restic stats
#   just restic-snapshots        # shorthand for: restic snapshots --host rofl
#
# This passes whatever you give it straight through. `forget`, `prune` and
# `unlock` are as destructive here as anywhere else, and the enclave's backup
# sidecar may be running against the same repository.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/_restic-common.sh
. "$SCRIPT_DIR/_restic-common.sh"

[ "$#" -gt 0 ] || fail "usage: just restic <command> [args…]   (e.g. 'just restic snapshots')"

restic_preflight
exec docker run --rm -i "${RESTIC_ENV[@]}" "$RESTIC_IMAGE" "$@"
