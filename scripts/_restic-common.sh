#!/usr/bin/env bash
#
# Shared setup for the restic/R2 scripts. Sourced, not executed.
#
# The rclone scripts each repeat their own setup, which was fine for two. The
# restic side has three entry points that must all agree on the image digest,
# the host name and the env mapping, so those live here once — bumping the
# pinned digest in one place cannot leave another script on the old binary.
#
# Provides: restic()  resticsh()  R2_ENDPOINT  RESTIC_HOST  ok/warn/fail/step

# Pinned identically to the compose sidecars — the scripts test the exact
# binary that runs in the enclave.
RESTIC_IMAGE="docker.io/restic/restic:0.17.3@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a"

# Must match RESTIC_HOST in the compose services: restic groups snapshots by
# host for retention, so a mismatch here silently creates a second group that
# `restic forget` then keeps in full, forever.
RESTIC_HOST="rofl"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- locate repo root + load .env -------------------------------------------
_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$_SCRIPT_DIR/.." && pwd)

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$ROOT_DIR/.env"
  set +a
fi

restic_preflight() {
  command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"

  local missing=0 var val
  for var in R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY RESTIC_PASSWORD; do
    eval "val=\${$var:-}"
    if [ -z "$val" ]; then
      printf '  \033[31m✗\033[0m unset: %s\n' "$var" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || fail "fill the above into .env (see .env.example) and retry"

  R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

  RESTIC_ENV=(
    -e HOME=/tmp
    -e RESTIC_CACHE_DIR=/tmp/restic-cache
    -e RESTIC_REPOSITORY="s3:${R2_ENDPOINT}/${R2_BUCKET}"
    -e RESTIC_PASSWORD="$RESTIC_PASSWORD"
    -e AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    -e AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    -e AWS_DEFAULT_REGION=auto
  )

  docker image inspect "$RESTIC_IMAGE" >/dev/null 2>&1 || docker pull -q "$RESTIC_IMAGE" >/dev/null
}

restic() { docker run --rm -i "${RESTIC_ENV[@]}" "$RESTIC_IMAGE" "$@"; }

# Round-trips run wholly inside the container: a host bind mount on macOS can
# surface as "input/output error" mid-read and be misread as a restic failure.
resticsh() { docker run --rm -i "${RESTIC_ENV[@]}" --entrypoint /bin/sh "$RESTIC_IMAGE" -c "$1"; }

# Map restic's failure text onto the thing that is actually misconfigured.
# Shared so all three scripts explain a failure the same way.
restic_explain() {
  case "$1" in
    *"does not exist"*|*"unable to open config file"*)
      echo "no repository at s3:${R2_ENDPOINT}/${R2_BUCKET} — create it once with 'just restic-init'" ;;
    *"signature"*|*"AccessDenied"*|*"InvalidAccessKeyId"*)
      echo "credentials rejected — re-check R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY and the token's bucket scope" ;;
    *"wrong password"*|*"invalid data returned"*)
      echo "RESTIC_PASSWORD does not open this repository (this value is used RAW — do not obscure it)" ;;
    *)
      echo "cannot reach the repository — check R2_ACCOUNT_ID and R2_BUCKET" ;;
  esac
}
