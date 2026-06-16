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

# Peek into the encrypted Akave bucket via the running sync sidecar.
# Filenames you see are decrypted; on the bucket itself they're ciphertext.
inspect-bucket:
    docker compose exec rclone-sync rclone lsf crypt:

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

ship: build set-secrets update deploy
