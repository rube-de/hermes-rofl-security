#!/usr/bin/env bash
#
# Purge regenerable cache cruft from the Akave bucket — the exact directory
# prefixes the rclone-sync sidecar now EXCLUDES (.cache, .venv, node_modules,
# …). Because sync excludes them, its --delete-during never prunes them, so a
# one-shot external purge is the only way to reclaim that space.
#
# SAFE against a LIVE enclave: sync no longer reads or writes these prefixes,
# so this deletes a disjoint set of objects from what the sidecar syncs
# (session files, config.yaml, vault/). Those are never touched.
#
# Only ROOT-level prefixes are targeted — that's where the cruft is: the old
# broken `**/.cache/**` excludes matched *nested* dirs but missed root-level
# ones, so root-level caches are exactly what leaked into the bucket.
#
# Usage:
#   just purge-bucket-cruft            # DRY-RUN: list + size each prefix, delete nothing
#   just purge-bucket-cruft --confirm  # actually purge
#
set -euo pipefail

# Pinned identically to the compose sidecars / test-akave.
RCLONE_IMAGE="docker.io/rclone/rclone:1.69@sha256:1f497a86a6466395e62a5886613a14b7b18809543566ef9fa35fa1371a7ecc0f"

# Exactly the directory prefixes excluded by rclone-sync in compose.yaml.
PREFIXES=".cache .venv node_modules __pycache__ .npm .pytest_cache .mypy_cache .ruff_cache .tox logs"

CONFIRM=0
[ "${1:-}" = "--confirm" ] && CONFIRM=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

human() { awk -v b="${1:-0}" 'BEGIN{ split("B KB MB GB TB",u," "); i=1; while(b>=1024&&i<5){b/=1024;i++} printf (i==1?"%d%s":"%.1f%s"), b, u[i] }'; }

# --- locate repo root + load .env --------------------------------------------
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
missing=0
for var in AKAVE_ENDPOINT AKAVE_ACCESS_KEY AKAVE_SECRET_KEY AKAVE_BUCKET \
           RCLONE_CRYPT_PASSWORD RCLONE_CRYPT_SALT; do
  eval "val=\${$var:-}"
  [ -n "$val" ] || { printf '  \033[31m✗\033[0m unset: %s\n' "$var" >&2; missing=1; }
done
[ "$missing" -eq 0 ] || fail "fill the Akave secrets into .env (see .env.example)"
ok "docker + secrets present (bucket: $AKAVE_BUCKET)"

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
rclone() { docker run --rm "${RCLONE_ENV[@]}" "$RCLONE_IMAGE" "$@"; }

docker image inspect "$RCLONE_IMAGE" >/dev/null 2>&1 || docker pull -q "$RCLONE_IMAGE" >/dev/null

# size of a crypt prefix -> echoes "count bytes" (0 0 if absent)
prefix_size() {
  local out count bytes
  out=$(rclone size "crypt:$1" --json 2>/dev/null || echo '{"count":0,"bytes":0}')
  count=$(printf '%s' "$out" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
  bytes=$(printf '%s' "$out" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
  echo "${count:-0} ${bytes:-0}"
}

# --- scan --------------------------------------------------------------------
step "Scanning cache prefixes in crypt:$AKAVE_BUCKET"
found=""
total_bytes=0
for p in $PREFIXES; do
  set -- $(prefix_size "$p"); count=$1; bytes=$2
  if [ "$count" -gt 0 ]; then
    printf '  %-15s %6s objs  %9s\n' "$p/" "$count" "$(human "$bytes")"
    found="$found $p"
    total_bytes=$((total_bytes + bytes))
  fi
done

if [ -z "$found" ]; then
  step "Nothing to purge — bucket is already clean"
  exit 0
fi
printf '  %-15s %9s objs(total) %9s\n' "—" "" "$(human "$total_bytes")"

# --- dry-run gate ------------------------------------------------------------
if [ "$CONFIRM" -eq 0 ]; then
  step "DRY-RUN — nothing deleted"
  printf '  Re-run to purge the above:\n    just purge-bucket-cruft --confirm\n'
  exit 0
fi

# --- purge -------------------------------------------------------------------
step "Purging (--confirm)"
for p in $found; do
  if rclone purge "crypt:$p" 2>/dev/null; then
    ok "purged $p/"
  else
    warn "purge of $p/ returned non-zero (possibly emptied concurrently)"
  fi
done

# --- verify ------------------------------------------------------------------
step "Verifying"
left=0
for p in $found; do
  set -- $(prefix_size "$p"); count=$1
  [ "$count" -eq 0 ] || { warn "$p/ still has $count object(s)"; left=$((left + 1)); }
done
if [ "$left" -eq 0 ]; then
  ok "all targeted prefixes empty"
  printf '\n\033[32mDone.\033[0m Hermes regenerates these caches locally; sync keeps ignoring them.\n'
else
  fail "$left prefix(es) not fully purged — re-run, or check for a concurrent writer"
fi
