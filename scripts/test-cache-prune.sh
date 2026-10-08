#!/usr/bin/env bash
#
# Regression test for the cache-prune boot service.
#
# Renders each compose file the way the runtime does, takes the cache-prune
# block out of it verbatim, and runs it in the service's own pinned busybox
# image against a throwaway fixture bind-mounted at /data. Never against the
# hermes-data volume: the fixture is a fresh mktemp directory passed as an
# explicit bind, which docker cannot resolve to a named volume.
#
# Repo checkouts and installed tools must survive; the package caches must go.
#
# Usage:
#   just test-cache-prune                  # compose.yaml + compose-openrouter.yaml
#   scripts/test-cache-prune.sh FILE...    # any compose file, e.g. an old revision
#
set -euo pipefail

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; FAILED=1; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

if [ $# -eq 0 ]; then
  set -- "$ROOT_DIR/compose.yaml" "$ROOT_DIR/compose-openrouter.yaml"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cache-prune-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/empty.env"
FAILED=0

# Must survive the prune: checkouts (one dot-named, which a glob would skip but
# a broader rule might not), an installed CLI, and agent data next to the caches.
SURVIVE="
repo/hermes-agent/.git/HEAD
repo/hermes-agent/README.md
repo/.dotted-checkout/.git/HEAD
home/.npm-global/bin/gh
home/.npm-global/lib/node_modules/gh/package.json
state.db
vault/note.md
profiles/default/home/src/main.go
"
# Must be removed: one file inside each genuine cache the block targets.
REMOVE="
home/.local/share/pnpm/store/v3/files/index
home/.cache/uv/wheels/pkg.whl
home/.cache/pnpm/metadata/registry.json
home/.cache/node/corepack/pnpm.tgz
home/.npm/_cacache/index-v5/entry
home/.cache/pip/http/blob
profiles/default/home/go/pkg/mod/cache/download/mod.zip
toolchains/go1.23-download/go.tgz
"
# What the survival log must report: two repo entries, one installed binary.
KEPT="2 entries in repo/, 1 in .npm-global/bin"

# Scrubbed environment and an empty env file, so neither .env nor a
# dotenv-loaded `just` environment can interpolate secrets into the render.
render() {
  env -i PATH="$PATH" HOME="$HOME" \
    ${DOCKER_HOST:+"DOCKER_HOST=$DOCKER_HOST"} \
    ${DOCKER_CONTEXT:+"DOCKER_CONTEXT=$DOCKER_CONTEXT"} \
    ${DOCKER_CONFIG:+"DOCKER_CONFIG=$DOCKER_CONFIG"} \
    docker compose --env-file "$WORK/empty.env" -f "$1" config --format json \
    2>"$WORK/render.err"
}

seed() {
  local rel
  for rel in $SURVIVE $REMOVE; do
    mkdir -p "$1/$(dirname "$rel")"
    printf '%s\n' "$rel" > "$1/$rel"
  done
}

n=0
for file in "$@"; do
  n=$((n + 1))
  step "$file"
  [ -f "$file" ] || { bad "no such file"; continue; }

  if ! json=$(render "$file"); then
    sed 's/^/    /' "$WORK/render.err" >&2
    bad "docker compose could not render it"
    continue
  fi
  svc=$(printf '%s' "$json" | jq -c '.services["cache-prune"] // empty')
  [ -n "$svc" ] || { bad "no cache-prune service"; continue; }
  printf '%s' "$svc" > "$WORK/svc.$n.json"

  # The test runs `/bin/sh -c <block>` with /data as a bind. Check the service
  # really is that shape, or a pass here would say nothing about production.
  image=$(printf '%s' "$svc" | jq -r '.image')
  printf '%s' "$svc" | jq -e '.entrypoint == ["/bin/sh"]' >/dev/null \
    || { bad "entrypoint is not [/bin/sh]"; continue; }
  printf '%s' "$svc" | jq -e '(.command | length) == 2 and .command[0] == "-c"' >/dev/null \
    || { bad "command is not [-c, <script>]"; continue; }
  printf '%s' "$svc" | jq -e '[.volumes[] | select(.source == "hermes-data" and .target == "/data")] | length == 1' >/dev/null \
    || { bad "hermes-data is not mounted at /data"; continue; }
  # `compose config` re-escapes every literal $ as $$ so its output stays valid
  # compose; the runtime turns $$ back into $ when it starts the container.
  script=$(printf '%s' "$svc" | jq -r '.command[1] | gsub("\\$\\$"; "$")')
  ok "rendered: $image, hermes-data at /data"

  if docker run --rm --network none --entrypoint /bin/sh "$image" -n -c "$script"; then
    ok "shell syntax (busybox sh -n)"
  else
    bad "shell syntax error"; continue
  fi

  fixture="$WORK/data.$n"
  mkdir "$fixture"
  seed "$fixture"
  # wait_for_restore only proceeds on a sentinel holding this kernel's boot_id;
  # without it the block waits 30 minutes and then skips the prune entirely.
  docker run --rm --network none --entrypoint /bin/cat "$image" \
    /proc/sys/kernel/random/boot_id > "$fixture/.restore-complete"

  # busybox `timeout` bounds the run in case the gate ever stops matching.
  if ! out=$(docker run --rm --network none \
        --mount "type=bind,source=$fixture,target=/data" \
        -e CACHE_PRUNE_LINGER=0 \
        --entrypoint /bin/sh "$image" \
        -c 'exec timeout 120 /bin/sh -c "$1"' cache-prune "$script" 2>&1); then
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    bad "cache-prune block exited non-zero"; continue
  fi
  case "$out" in
    *"[cache-prune] prune complete"*) ok "block ran to \"prune complete\"" ;;
    *) printf '%s\n' "$out" | sed 's/^/    /' >&2
       bad "block never reached the prune"; continue ;;
  esac

  for rel in $SURVIVE; do
    if [ "$(cat "$fixture/$rel" 2>/dev/null)" = "$rel" ]; then
      ok "kept     $rel"
    else
      bad "DELETED  $rel"
    fi
  done
  for rel in $REMOVE; do
    if [ -e "$fixture/$rel" ]; then
      bad "left     $rel"
    else
      ok "removed  $rel"
    fi
  done

  for when in before after; do
    if printf '%s\n' "$out" | grep -qF "[cache-prune] $when: $KEPT" \
       && grep -qF "cache-prune    $when: $KEPT" "$fixture/.boot-trace"; then
      ok "logged and traced \"$when: $KEPT\""
    else
      bad "missing \"$when: $KEPT\" in output or .boot-trace"
    fi
  done
done

# The two variants are hand-kept copies with no generator behind them, so a fix
# applied to one alone is the likeliest way for this regression to come back.
if [ "$n" -gt 1 ]; then
  step "Variants agree"
  i=2
  while [ "$i" -le "$n" ]; do
    if [ -f "$WORK/svc.1.json" ] && cmp -s "$WORK/svc.1.json" "$WORK/svc.$i.json"; then
      ok "cache-prune in file $i matches file 1"
    else
      bad "cache-prune in file $i differs from file 1"
    fi
    i=$((i + 1))
  done
fi

echo
[ "$FAILED" -eq 0 ] || die "cache-prune regression test FAILED"
ok "cache-prune regression test passed"
