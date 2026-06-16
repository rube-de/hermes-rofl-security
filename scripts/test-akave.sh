#!/usr/bin/env bash
#
# Smoke-test the Akave (S3 + rclone crypt) connection the ROFL sidecars use.
#
# Runs locally with the SAME pinned rclone image and env-var mapping as the
# rclone-restore / rclone-sync services in the compose files, so a pass here
# means the sidecars will boot and restore/sync on ROFL. Run before `just ship`.
#
# Usage:
#   just test-akave              # full check incl. encrypted write round-trip
#   just test-akave --read-only  # connectivity + crypt only, no writes
#
# Reads the same six secrets the sidecars consume, from .env (or the ambient
# environment when invoked via `just`, which dotenv-loads):
#   AKAVE_ENDPOINT  AKAVE_ACCESS_KEY  AKAVE_SECRET_KEY  AKAVE_BUCKET
#   RCLONE_CRYPT_PASSWORD  RCLONE_CRYPT_SALT   (the latter two already obscured)
#
set -euo pipefail

# Pinned identically to the compose sidecars — test the exact prod binary.
RCLONE_IMAGE="docker.io/rclone/rclone:1.69@sha256:1f497a86a6466395e62a5886613a14b7b18809543566ef9fa35fa1371a7ecc0f"

READ_ONLY=0
[ "${1:-}" = "--read-only" ] && READ_ONLY=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- locate repo root + load .env -------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$ROOT_DIR/.env"
  set +a
fi

# --- preflight ---------------------------------------------------------------
step "Preflight"
command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"
ok "docker present"

missing=0
for var in AKAVE_ENDPOINT AKAVE_ACCESS_KEY AKAVE_SECRET_KEY AKAVE_BUCKET \
           RCLONE_CRYPT_PASSWORD RCLONE_CRYPT_SALT; do
  eval "val=\${$var:-}"
  if [ -z "$val" ]; then
    printf '  \033[31m✗\033[0m unset: %s\n' "$var" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || fail "fill the above into .env (see .env.example) and retry"
ok "all six Akave secrets present"
ok "bucket: $AKAVE_BUCKET   endpoint: $AKAVE_ENDPOINT"

# --- rclone runner (identical env mapping to the compose sidecars) -----------
RCLONE_ENV=(
  -e HOME=/tmp
  -e RCLONE_CONFIG_AKAVE_TYPE=s3
  -e RCLONE_CONFIG_AKAVE_PROVIDER=Other
  -e RCLONE_CONFIG_AKAVE_REGION=akave-network
  -e RCLONE_CONFIG_AKAVE_ENDPOINT="$AKAVE_ENDPOINT"
  -e RCLONE_CONFIG_AKAVE_ACCESS_KEY_ID="$AKAVE_ACCESS_KEY"
  -e RCLONE_CONFIG_AKAVE_SECRET_ACCESS_KEY="$AKAVE_SECRET_KEY"
  -e RCLONE_CONFIG_AKAVE_FORCE_PATH_STYLE=true
  -e RCLONE_CONFIG_CRYPT_TYPE=crypt
  -e RCLONE_CONFIG_CRYPT_REMOTE="akave:$AKAVE_BUCKET"
  -e RCLONE_CONFIG_CRYPT_FILENAME_ENCRYPTION=standard
  -e RCLONE_CONFIG_CRYPT_PASSWORD="$RCLONE_CRYPT_PASSWORD"
  -e RCLONE_CONFIG_CRYPT_PASSWORD2="$RCLONE_CRYPT_SALT"
)
rclone() { docker run --rm -i "${RCLONE_ENV[@]}" "$RCLONE_IMAGE" "$@"; }

# Pull once up front so probe output isn't interleaved with pull progress.
docker image inspect "$RCLONE_IMAGE" >/dev/null 2>&1 || docker pull -q "$RCLONE_IMAGE" >/dev/null

# --- 1. raw S3: endpoint + creds + bucket ------------------------------------
step "1/3  S3 bucket reachable (endpoint + credentials + bucket name)"
if ! raw=$(rclone lsf "akave:$AKAVE_BUCKET" 2>&1); then
  printf '%s\n' "$raw" | sed 's/^/    /' >&2
  fail "cannot list akave:$AKAVE_BUCKET — check endpoint, access/secret key, and bucket name"
fi
ok "listed akave:$AKAVE_BUCKET ($(printf '%s' "$raw" | grep -c . ) entries)"

# --- 2. crypt remote: passphrase + salt valid --------------------------------
# This is exactly what rclone-restore runs first; if the obscured crypt values
# are malformed, it fails here rather than mid-restore on ROFL.
step "2/3  Crypt remote usable (RCLONE_CRYPT_PASSWORD / _SALT decode)"
if ! crypt=$(rclone lsf crypt: 2>&1); then
  printf '%s\n' "$crypt" | sed 's/^/    /' >&2
  fail "crypt: unusable — re-check the obscured password/salt (regenerate via 'just obscure')"
fi
ok "crypt: opens ($(printf '%s' "$crypt" | grep -c . ) decrypted entries)"

# --- 3. encrypted write round-trip -------------------------------------------
if [ "$READ_ONLY" -eq 1 ]; then
  step "3/3  Write round-trip — SKIPPED (--read-only)"
  printf '\n\033[32mAkave connection OK\033[0m (read-only checks passed)\n'
  exit 0
fi

step "3/3  Encrypted write round-trip (write → read back → verify ciphertext → delete)"
# Namespace the probe under a dedicated prefix so an orphaned object (e.g. a
# hard kill between write and cleanup) stays isolated from real Hermes data and
# is trivially sweepable — never dropped at the bucket root next to live state.
testname="akave-conntest-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}.txt"
marker="_conntest/$testname"
payload="akave round-trip probe $(date -u +%FT%TZ) host=$(hostname) pid=$$"

cleanup() { rclone deletefile "crypt:$marker" >/dev/null 2>&1 || true; }
trap cleanup EXIT

printf '%s\n' "$payload" | rclone rcat "crypt:$marker" \
  || fail "write failed (crypt:$marker)"
ok "wrote crypt:$marker"

got=$(rclone cat "crypt:$marker") || fail "read-back failed"
[ "$got" = "$payload" ] || fail "decrypted content does not match what was written"
ok "read back and decrypted content matches"

# The path must be ciphertext on the raw S3 side — proves filename encryption is
# actually on. Capture the listing and check rclone's status FIRST: a failed
# lsf must be a hard error, never silently read as "plaintext absent" — a bare
# `lsf | grep` pipeline would mask an lsf failure as a false PASS.
raw_listing=$(rclone lsf "akave:$AKAVE_BUCKET") \
  || fail "could not list raw bucket to verify ciphertext"
if printf '%s\n' "$raw_listing" | grep -Fq "_conntest"; then
  fail "plaintext path '_conntest/' visible on raw bucket — filename encryption NOT active"
fi
ok "raw bucket shows only ciphertext names (filename encryption active)"

# Delete explicitly and confirm via rclone's own exit status, then disarm the
# trap — no trailing `lsf | grep` that could mask a failed listing as "deleted".
rclone deletefile "crypt:$marker" \
  || fail "could not delete test object crypt:$marker — remove it manually"
trap - EXIT
ok "test object deleted"

printf '\n\033[32mAkave connection OK\033[0m — restore + sync sidecars will work with these secrets\n'
