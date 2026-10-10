#!/usr/bin/env bash
#
# Regression test for the cache-prune boot service.
#
# Renders each compose file the way the runtime does, takes the cache-prune
# block out of it verbatim, and runs it in the service's own pinned busybox
# image against a throwaway fixture volume mounted at /data. Never against the
# hermes-data volume: each fixture is a new volume with a random name, which
# the test refuses to reuse if it already exists, and removes on exit.
#
# A volume rather than a bind of a host directory, because that is what the
# machine prunes: on Docker Desktop a bind keeps the host's permissions, and
# container root then cannot clear Go's read-only module cache as it does there.
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
VOLUMES=""
cleanup() {
  local vol
  for vol in $VOLUMES; do
    docker volume rm "$vol" >/dev/null 2>&1 || printf 'left volume %s behind\n' "$vol" >&2
  done
  # u+w first: a read-only module tree the prune failed to remove would stop rm.
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
: > "$WORK/empty.env"
FAILED=0

# Review runs laid out the way the worker leaves them on the machine.
OC_RUN=security-review-runs/oasis-core/20261008-142136-405dd36
CLI_RUN=security-review-runs/cli/20261006T130003Z
WORKER_HOME=profiles/securityreviewworker/home

# Must survive the prune: checkouts (one dot-named, which a glob would skip but
# a broader rule might not), installed CLIs, agent data next to the caches, and
# the review runs' own output beside the Go caches cleared out of them.
SURVIVE="
repo/hermes-agent/.git/HEAD
repo/hermes-agent/README.md
repo/.dotted-checkout/.git/HEAD
home/.npm-global/bin/gh
home/.npm-global/lib/node_modules/gh/package.json
state.db
vault/note.md
profiles/default/home/src/main.go
$WORKER_HOME/.bun/bin/bun
$WORKER_HOME/.bun/install/global/node_modules/tool/package.json
$OC_RUN/govulncheck-results.json
$OC_RUN/worker-log.txt
$OC_RUN/tools/install_go.py
$OC_RUN/cache/go-path/bin/govulncheck
$CLI_RUN/worker-prompt.md
$CLI_RUN/scans/semgrep-results.json
$CLI_RUN/tools/gobin/govulncheck
$CLI_RUN/tools/govulncheck-findings.tar.gz
"
# Must be removed: one file inside each genuine cache the block targets.
REMOVE="
home/.local/share/pnpm/store/v3/files/index
home/.cache/uv/wheels/pkg.whl
home/.cache/pnpm/metadata/registry.json
home/.cache/node/corepack/pnpm.tgz
home/.npm/_cacache/index-v5/entry
home/.cache/pip/http/blob
home/.cache/go-build/00/0011-d
profiles/default/home/go/pkg/mod/cache/download/mod.zip
$WORKER_HOME/.bun/install/cache/pkg@1.0.0/package.json
$WORKER_HOME/.cache/go-build/00/0011-d
$WORKER_HOME/.cache/pip/http/blob
$WORKER_HOME/.cache/pip-audit/cache.json
$WORKER_HOME/.cache/node/corepack/pnpm.tgz
$WORKER_HOME/.cache/pnpm/metadata/registry.json
toolchains/go1.23-download/go.tgz
$OC_RUN/cache/go-build/00/0011-d
$OC_RUN/cache/go-mod/golang.org/x/mod@v0.20.0/go.mod
$OC_RUN/tools/go/bin/go
$OC_RUN/tools/go1.27.0.linux-amd64.tar.gz
$CLI_RUN/tools/gomodcache/github.com/spf13/cobra@v1.8.0/go.mod
$CLI_RUN/tools/go/bin/go
$CLI_RUN/tools/go.tgz
"
# Go writes its module cache read-only; the prune has to get through that.
READ_ONLY="
profiles/default/home/go/pkg/mod
$OC_RUN/cache/go-mod
$CLI_RUN/tools/gomodcache
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

# Shell that builds the fixture inside the volume, each file holding its own
# path so a survivor can be told from a recreated one.
seed_script() {
  local rel
  for rel in $SURVIVE $REMOVE; do
    printf 'mkdir -p "/data/%s"\n' "$(dirname "$rel")"
    printf 'echo "%s" > "/data/%s"\n' "$rel" "$rel"
  done
  for rel in $READ_ONLY; do
    printf 'chmod -R a-w "/data/%s"\n' "$rel"
  done
  # wait_for_restore only proceeds on a sentinel holding this kernel's boot_id;
  # without it the block waits 30 minutes and then skips the prune entirely.
  echo 'cat /proc/sys/kernel/random/boot_id > /data/.restore-complete'
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

  # The test runs `/bin/sh -c <block>` with a volume at /data. Check the service
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

  # `volume create` quietly reuses an existing volume, so check first.
  vol="cache-prune-test-${WORK##*.}-$n"
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    bad "volume $vol already exists, not touching it"; continue
  fi
  docker volume create "$vol" >/dev/null
  VOLUMES="$VOLUMES $vol"
  if ! seed_script | docker run --rm -i --network none \
        --mount "type=volume,source=$vol,target=/data" \
        --entrypoint /bin/sh "$image" -e -s; then
    bad "could not seed the fixture volume"; continue
  fi

  # busybox `timeout` bounds the run in case the gate ever stops matching.
  if ! out=$(docker run --rm --network none \
        --mount "type=volume,source=$vol,target=/data" \
        -e CACHE_PRUNE_LINGER=0 \
        --entrypoint /bin/sh "$image" \
        -c 'exec timeout 120 /bin/sh -c "$1"' cache-prune "$script" 2>&1); then
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    bad "cache-prune block exited non-zero"; continue
  fi

  # Copied out whole, so the checks below read what the block left behind.
  fixture="$WORK/data.$n"
  mkdir "$fixture"
  if ! docker run --rm --network none \
        --mount "type=volume,source=$vol,target=/data" \
        --entrypoint /bin/tar "$image" -C /data -cf - . \
      | tar -C "$fixture" -xf -; then
    bad "could not copy the fixture volume out"; continue
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
    disk="disk $when: [^ ]+ used, [^ ]+ free of [^ ]+, [0-9]+ inodes free\$"
    if printf '%s\n' "$out" | grep -qE "^\[cache-prune\] $disk" \
       && grep -qE "cache-prune    $disk" "$fixture/.boot-trace"; then
      ok "logged and traced disk usage $when"
    else
      bad "missing \"disk $when\" usage in output or .boot-trace"
    fi
  done

  # The size listing exists for what the backup cannot see, so a checkout has
  # to show up in it.
  size="size [0-9]+M /data/repo/hermes-agent\$"
  if printf '%s\n' "$out" | grep -qE "^\[cache-prune\] $size" \
     && grep -qE "cache-prune    $size" "$fixture/.boot-trace"; then
    ok "logged and traced folder sizes, repo checkouts included"
  else
    printf '%s\n' "$out" | grep -F '[cache-prune] size ' | sed 's/^/    /' >&2 || true
    bad "size listing missing or without repo/hermes-agent"
  fi
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
