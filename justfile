set dotenv-load := true

network := "testnet"

default:
    @just --list

create:
    oasis rofl create --network {{network}}

build:
    oasis rofl build

set-secrets:
    @test -f .env || (echo ".env not found — copy .env.example and fill it in" && exit 1)
    oasis rofl secret import --force .env

update:
    oasis rofl update -y

deploy:
    oasis rofl deploy -y

show:
    oasis rofl machine show

logs:
    oasis rofl machine logs -y

# Restart the machine (or start it if stopped). Sync sidecar flushes on the
# SIGTERM before shutdown, so no unsynced writes are lost.
restart:
    oasis rofl machine restart -y

identity:
    oasis rofl identity

trust-root:
    oasis rofl trust-root

# Obscure a password or salt for RCLONE_CRYPT_* secrets.
# Usage:  just obscure 'my-passphrase'
# Pipe the output into .env (or rerun and copy/paste). Both values must be obscured.
obscure value:
    @docker run --rm rclone/rclone:1.69@sha256:1f497a86a6466395e62a5886613a14b7b18809543566ef9fa35fa1371a7ecc0f obscure '{{value}}'

# The rclone sidecars were removed at the restic cutover, so there is no
# container to exec into. Use `just restic ls latest` for the live backup;
# `just test-akave` still reaches the legacy Akave bucket for rollback.
# (removed: inspect-bucket)

# Smoke-test the Akave connection (creds, bucket, crypt round-trip) locally,
# using the same pinned rclone image + env mapping as the sidecars.
# Pass --read-only to skip the write/delete round-trip.
test-akave *args:
    @./scripts/test-akave.sh {{args}}

# Purge regenerable cache cruft (.cache, .venv, …) left in the Akave bucket by
# the old broken excludes. Dry-run by default; pass --confirm to delete. Safe
# while the enclave is live — sync excludes these exact prefixes.
purge-bucket-cruft *args:
    @./scripts/purge-bucket-cruft.sh {{args}}

# Deliberately not done by the sidecars: an init on a boot path would turn any
# transient error into a silent second empty repository beside the real one.
# Create the restic repository on Cloudflare R2 (one-time, safe to re-run).
restic-init:
    @./scripts/restic-init.sh

# Uses the same pinned restic image + env mapping as the sidecars, so a pass
# here means they will boot. Pass --read-only to skip the write round-trip.
# Smoke-test the R2 repository: creds, integrity, backup round-trip.
test-r2 *args:
    @./scripts/test-r2.sh {{args}}

# Runs the real block, rendered from each compose file, in its pinned busybox
# image against a throwaway fixture: never the hermes-data volume.
# Check cache-prune keeps repo checkouts and installed tools, removes caches.
test-cache-prune *files:
    @./scripts/test-cache-prune.sh {{files}}

# Fail if the newest R2 snapshot is older than MAX_AGE_HOURS (default 3).
# Exit: 0 fresh, 1 stale, 2 repository unreachable. Run this OFF the machine —
# the in-enclave watchdog cannot notice that the machine itself is gone.
backup-check:
    @./scripts/backup-check.sh

# List restore points in the R2 repository.
restic-snapshots:
    @./scripts/restic-run.sh snapshots --host rofl

# Passes straight through, so forget/prune/unlock are as destructive as ever,
# and the enclave's backup sidecar may be using the same repository.
# Run any restic command against R2 (e.g. just restic ls latest).
restic *args:
    @./scripts/restic-run.sh {{args}}

ship: build set-secrets update deploy
