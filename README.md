# hermes-rofl-security

Hermes Agent running inside an Oasis ROFL TDX enclave. Agent state (`/opt/data`)
and credentials live in the TEE; prompts and tool calls still exit to whichever
inference provider you wire up (Z.AI's GLM coding plan, OpenRouter, …).

Two ways in: Telegram (outbound long-polling, both compose files) and — with the
default `compose.yaml` — a web dashboard fronted by a [SIWE wallet
gate](https://github.com/rube-de/hermes-wallet-gateway), so only allowlisted
Ethereum addresses can reach it. See "Dashboard access" below.

## What's in here

| File                     | Origin              | Purpose                                                      |
| ------------------------ | ------------------- | ------------------------------------------------------------ |
| `rofl.yaml`              | `oasis rofl init`   | TEE manifest. Resources tuned to ~playground_short.          |
| `compose.yaml`           | edited after init   | Default deployment — GLM + R2 backup + wallet-gated dashboards. |
| `compose-openrouter.yaml`| this repo           | Alternative deployment — Hermes against OpenRouter.          |
| `.env.example`           | this repo           | Names of the secrets you must `secret import`.               |
| `justfile`               | this repo           | Wrappers around the `oasis rofl ...` sequence.               |

Both compose files share a core shape: the pinned Hermes image plus the restic
backup services (see "Persistent storage" below) and a small `command:` wrapper. On
the very first boot — when no sentinel marker (`/opt/data/.compose-initialized`)
exists yet — the wrapper writes a default `config.yaml` from the heredoc and
drops the marker. On every subsequent boot it leaves `config.yaml` alone, so
whatever the user (or Hermes itself) has put there — added auxiliary
providers, swapped the model, configured skills — is the source of truth.

They differ in one way: `compose.yaml` additionally runs two web dashboards —
the stock `hermes-dashboard` and a `hermes-security-dashboard` — behind a single
`wallet-gateway` (see "Dashboard access" below), while `compose-openrouter.yaml`
is Telegram-only. Switching to OpenRouter as-is therefore drops the web
dashboards unless you port those services across.

## Choosing a provider

`rofl.yaml` pins exactly one compose file at `artifacts.container.compose`. To
switch between providers, edit that line:

```yaml
# rofl.yaml
artifacts:
  container:
    compose: compose.yaml             # Z.AI / GLM (default)
    # compose: compose-openrouter.yaml  # OpenRouter
```

After switching, `just build && just update && just deploy`. The bundle hash
changes — so the enclave identity will change too.

Secrets (`GLM_API_KEY`, `OPENROUTER_API_KEY`, `TELEGRAM_BOT_TOKEN`, …) are
**never** declared in `rofl.yaml`. They go through `oasis rofl secret import .env`
(wrapped as `just set-secrets`), which encrypts them to the enclave's key.

### Model selection

The model is hard-coded in each compose's inline heredoc — but only as a
**first-boot default**. Once `config.yaml` exists and the
`.compose-initialized` sentinel is dropped (after the first successful boot,
within seconds), the compose stops touching it. Edits made in `config.yaml`
at runtime are backed up to R2 and survive machine replacement. So:

- Pick the right default in compose if you don't want to log in and edit
  things after first deploy.
- For everything after that, change the model by editing
  `/opt/data/config.yaml` directly in the running container (or via
  whatever Hermes UI you use) — the change is picked up by the next backup
  cycle.
- To reset to compose defaults: delete `/opt/data/.compose-initialized` and
  restart the hermes service.

Defaults:
- `compose.yaml`: `default: glm-5-turbo`. Z.AI's coding plan also exposes
  `glm-5.1`, `glm-5`, `glm-4.7`, `glm-4.5-air`. See
  <https://docs.z.ai/devpack/tool/others>.
- `compose-openrouter.yaml`: `default: anthropic/claude-opus-4.6` (upstream
  Hermes' own example default). For a cheaper steady-state, swap to e.g.
  `anthropic/claude-haiku-4.6` or `google/gemini-3-flash-preview`. See
  <https://openrouter.ai/models>.

Note: because runtime `config.yaml` content is no longer pinned by the
attested bundle, a remote attester cannot tell which model the enclave is
serving — they can only verify it's running the bundled compose. If you
need attested model selection, you'd have to commit to clobbering
`config.yaml` on every boot, which throws away the user-config persistence
this design preserves.

## Prereqs

- `oasis` CLI logged in (`oasis wallet show`)
- ≥120 TEST on Sapphire testnet — faucet: <https://faucet.testnet.oasis.io/>
- An inference key matching your chosen compose file:
  - `compose.yaml` → Z.AI GLM Coding Plan key, <https://z.ai/subscribe>
  - `compose-openrouter.yaml` → OpenRouter key, <https://openrouter.ai/keys>
- Telegram bot token from `@BotFather`
- Your numeric Telegram user ID(s) — DM `@userinfobot` to get yours.
  Hermes denies all users by default; without `TELEGRAM_ALLOWED_USERS` set,
  the bot will silently ignore every message.
- (Optional) Group/supergroup chat IDs in `TELEGRAM_GROUP_ALLOWED_CHATS`
  (negative numbers, comma-separated). Leave empty for DM-only operation.
- (Optional, with `compose.yaml`) `OPENROUTER_API_KEY` — picked up by Hermes'
  auxiliary `auto` chain for vision/web_extract/session_search side-tasks.
  Leave empty in `.env` if you don't have one; `has_usable_secret()` filters
  short/empty values, so the auto chain just falls through.
- (Optional, with `compose.yaml`) `KIMI_API_KEY` — a Kimi Coding Plan key
  (<https://www.kimi.com/coding>), same auxiliary role as `OPENROUTER_API_KEY`.
  `compose.yaml` pins `KIMI_BASE_URL=https://api.kimi.com/coding`, because
  Hermes only auto-routes there for keys prefixed `sk-kimi-`. To make Kimi the
  default model instead, set `provider: kimi-coding` / `default: k3` /
  `api_mode: anthropic_messages` in `/opt/data/config.yaml` (see "Model
  selection" — compose's heredoc is first-boot only).
- (Default `compose.yaml` only) for the wallet-gated dashboard — see "Dashboard
  access" for the full flow:
  - The gateway image `ghcr.io/rube-de/hermes-wallet-gateway` (published, or
    build your own from that repo).
  - `WALLET_WHITELIST` — your Ethereum address(es), comma-separated `0x…`; only
    these can sign in.
  - `WALLET_SESSION_SECRET` — cookie HMAC key, `openssl rand -hex 32`.
  - `WALLET_DOMAIN` — the public proxy host, which you only learn *after* the
    first deploy (set it then).
- `just` (optional but assumed below)

## Bringup

```
cp .env.example .env   # then fill in real values
just create            # registers app on testnet, writes appId into rofl.yaml
just ship              # build + set-secrets + update + deploy
just logs              # follow enclave logs
```

The `set-secrets` step is the only path for credentials to reach the enclave.
Rotate the same way: edit `.env`, rerun `just set-secrets && just update`.

## Verifying you got a real TEE

```
just identity          # local enclave ID from the built bundle
just show              # on-chain record — enclave ID must match
just trust-root        # fresh attestation root
```

If the IDs from `identity` and `show` diverge, the deployed machine isn't
running the bundle you built.

## Caveats

- **Prompts are not confidential vs the inference provider.** The TEE protects
  API keys and agent state from the host operator, not from Z.AI / OpenRouter.
  For trustless inference, swap in a local Ollama sibling and bump to the
  Medium resource tier.
- **One exposed port, wallet-gated (`compose.yaml`).** The `wallet-gateway`
  publishes port 8080 — the only inbound surface — and refuses anything without
  a valid SIWE session from an allowlisted address. It path-routes `/security/*`
  to the security dashboard (3000) and everything else to the Hermes dashboard
  (9119); both, plus Hermes' OpenAI-compatible Gateway API (8642), stay
  unpublished, so the gateway is the sole perimeter. `compose-openrouter.yaml`
  publishes nothing — Telegram is outbound long-polling.
- **Pin images by digest for production.** In both compose files, `hermes` and
  `hermes-dashboard` use Hermes Agent **v0.21.5 (`v2026.9.24`)**, pinned by digest.
  The backup services, wallet gateway and security dashboard are also
  digest-pinned: the enclave identity is derived from the exact bundle, so a
  floating tag means the attested image can change and builds aren't reproducible.
  For a Hermes upgrade, resolve the chosen release with
  `docker buildx imagetools inspect docker.io/nousresearch/hermes-agent:<release-tag>`
  and update both services in both compose files to the same tag and digest.
  Then rebuild, update, redeploy — which rotates the enclave ID.
- **Switching compose files rotates the enclave ID.** Any client that pinned
  the previous attestation will need to re-trust the new identity.

## Persistent storage (Cloudflare R2 + restic)

ROFL `disk-persistent` storage is leased to a specific machine. When that lease
ends (funding runs out, you destroy the machine, the scheduler relocates it),
the disk goes with it. To survive that, Hermes's `/opt/data` is backed up to a
[Cloudflare R2](https://dash.cloudflare.com/) bucket with
[restic](https://restic.net/), via three services in `compose.yaml`:

- `restic-restore` — one-shot init container, the head of the boot chain.
  Restores the newest snapshot, but **only onto an empty volume**. A machine
  that already holds data is left alone, because restic restores with
  `--overwrite always` and a second pass would revert live agent state to the
  last snapshot. On a normal boot it therefore does nothing and exits in under a
  second. Everything else waits on the sentinel it publishes.
- `db-snapshot` — every `DB_SNAPSHOT_INTERVAL` seconds (default 1800), writes a
  clean copy of each live SQLite database to `db-snapshots/` with `VACUUM INTO`.
  The live files themselves are excluded from the backup: copying a hot SQLite
  file can capture a torn write.
- `restic-backup` — every `BACKUP_INTERVAL` seconds (default 3600), snapshots
  the volume. Every 24th cycle it applies retention (`--keep-hourly 24
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6`) and prunes.

The live SQLite files are excluded in favour of those clean copies, so
`restic-restore` reinstates each one to its live path before publishing the
sentinel — otherwise a recovered machine would come up with no databases at
all. `db-snapshots/.manifest` records where each copy belongs; an existing
live file is never overwritten. Each reinstated database is handed to the owner
of its directory (the agent user), since `restic-restore` runs as root and the
agent cannot write a root-owned database; every populated boot re-applies this
to the manifest's databases, so a volume restored before the fix heals itself.

### Why ordering is a sentinel and not `depends_on`

`podman-compose` maps `condition: service_completed_successfully` onto podman's
`--requires`, which does two things the compose syntax does not suggest: it
demands the dependency be **running**, and it **re-triggers** that one-shot once
per dependent. Every dependent therefore paid a full re-run of the restore —
~300s each on the old rclone path, which is rclone's idle timeout, and 1800s
once the restore started failing. That, and not object counts, is what made
boots take 40 minutes.

A fast one-shot makes it worse, not better: the re-triggered container has
already exited by the time podman checks, so the dependent fails outright with
`container state improper`. Cutting over to restic — where the restore returns
in under a second — turned the slowness into a total boot failure.

So no service depends on a one-shot. `cache-prune`, `db-snapshot` and
`restic-backup` each block on `/opt/data/.restore-complete` containing the
current kernel `boot_id`, which `restic-restore` writes only on success. The
whole chain now completes in about 5 seconds:

```
12:32:20  restic-restore  volume already holds data, not restoring
12:32:21  restic-backup   proceeded after 0s
12:32:21  db-snapshot     proceeded after 0s
12:32:25  cache-prune     proceeded after 5s -> prune complete
```

`just restic dump latest /opt/data/.boot-trace` prints exactly this for the last
boot — ROFL captures stdout from only some containers, so ordering is recorded
on the volume instead.

A fresh volume is never literally empty, which the restore guard has to account
for: the hermes image ships `.bashrc`, `.profile` and `.bash_logout` at
`/opt/data` (its HOME), and podman seeds a new named volume from image content at
mount time, before any process runs. Treating those as data would make a
brand-new machine look populated and skip the restore — losing exactly the
recovery this is for. They are excluded from the emptiness test; anything else
present still counts, so the guard stays fail-safe against overwriting live data.

The image's own entrypoint also writes to `/opt/data`: s6 `/init` runs
`cont-init.d/01-hermes-setup`, which creates the agent's directories plus
`.env`, `config.yaml` and `SOUL.md`. So every service on the hermes image must
gate on the sentinel in `entrypoint:` and then `exec
/opt/hermes/docker/entrypoint-dispatch.sh`; a gate in `command:` runs after
those writes and makes a fresh volume look populated to the restore guard.

This replaced an `rclone sync` mirror. The reason is that a mirror is not a
backup: it has no restore points, so anything that corrupts or deletes data
locally is faithfully copied to the remote on the next cycle, overwriting the
last good copy. restic keeps content-addressed, deduplicated snapshots, so you
can restore the state from before the damage.

Encryption is client-side and always on — restic encrypts every blob before it
leaves the machine, so Cloudflare only ever sees ciphertext. **`RESTIC_PASSWORD`
is the only thing that can decrypt the repository. Lose it and every snapshot is
unrecoverable; there is no recovery path and no second factor.** Store it in a
password manager before the first deploy. Note it is used *raw* — unlike the
old `RCLONE_CRYPT_*` values, it must **not** be passed through `just obscure`.

Hermes runs as user `hermes` (UID 10000) whose HOME is `/opt/data`, so any
CLI tool it invokes (codex, claude-code, …) lands its config and OAuth
tokens under `/opt/data/.codex/`, `/opt/data/.claude/`, etc. — all of that
is inside the backed-up volume. Nothing extra to wire up for auxiliary
providers' auth state.

`config.yaml` is full Hermes configuration (model selection, auxiliary
providers added via OAuth, skill settings, hooks, channel prompts, …) —
all of that survives machine replacement. The compose only writes to
`config.yaml` on the very first boot, gated by the
`/opt/data/.compose-initialized` sentinel file. Once that marker exists
(which happens within the first few seconds of the initial deploy and is
itself backed up), subsequent boots leave `config.yaml` entirely alone —
the user/agent is the sole writer.

The exclude list lives inline in the `restic-backup` service. Broadly, it drops
regenerable caches (`cache/`, `logs/`, `toolchains/`, `node_modules`, `.venv`,
`__pycache__`, …), the repo checkouts in `repo/` and the tools installed under
`home/.npm-global`, the live SQLite files in favour of
the `VACUUM INTO` copies, and the machine-namespaced runtime state that Hermes'
own `backup.py` skips on import — `gateway_state.json` above all, since a stale
value leaves the gateway stuck "starting" and disconnected from the portal.

Repo checkouts and installed tools are not caches: the boot-time `cache-prune`
service leaves both alone, so they survive restarts and redeploys. They are
still excluded from the backup, though, so a recovery onto a fresh volume comes
back without them.

There's also a `/opt/data/vault/` directory created on Hermes boot — drop any
file you want preserved across machine replacement into it (or anywhere
under `/opt/data/` except the excluded paths).

### One-time setup

1. Create a bucket and an S3 API token at
   <https://dash.cloudflare.com/> → R2. Scope the token to that one bucket with
   **Object Read & Write**. The Secret Access Key is shown **once** — copy it
   immediately. You also need your R2 Account ID from the same page.

2. Generate the repository password locally. This is the single point of total
   data loss, so treat it accordingly:

   ```sh
   openssl rand -base64 48        # -> RESTIC_PASSWORD, save in a password manager
   ```

   Do **not** run it through `just obscure` — that is an rclone-only encoding
   and restic would take the obscured text as the literal password.

3. Fill in `.env` (R2 + existing Hermes secrets), create the repository once,
   then push the bundle on-chain:

   ```sh
   cp .env.example .env       # then edit
   just restic-init           # one-time; safe to re-run, never runs on the boot path
   just test-r2               # creds + integrity + backup round-trip
   just set-secrets           # = oasis rofl secret import --force .env
   just update                # publishes the updated manifest
   ```

   `restic init` is deliberately kept off the boot path: run there, any
   transient error would silently create a second empty repository beside the
   real one, and backups would start accumulating in the wrong place.

### Rotating a single secret

Reading a value into the CLI via file avoids putting it in shell history:

```sh
printf '%s' "$NEW_VALUE" > /tmp/secret && \
  oasis rofl secret set R2_SECRET_ACCESS_KEY /tmp/secret && \
  rm /tmp/secret
just update
```

Or rotate the whole bundle: edit `.env`, `just set-secrets && just update`.

Changing a secret *value* needs `secret set` + `just update` + `just restart`.
A compose *edit* needs the full `just ship` — a restart reuses the old enclave.

### Inspecting and restoring

```sh
just restic-snapshots                  # restore points, newest last
just restic ls latest                  # what's in the newest snapshot
just restic dump latest /opt/data/.boot-trace   # boot ordering of the last boot
just restic stats                      # repository size
```

To restore onto a machine that already holds data — which `restic-restore`
refuses to do on its own, by design — say so explicitly:

```sh
docker compose run --rm -e RESTIC_FORCE_RESTORE=1 restic-restore
```

To roll a machine back to an earlier snapshot — recovering onto the same
volume is deliberately refused — select it by ID and recover onto a fresh
volume. Tag both snapshots first so retention cannot delete them mid-recovery
(`--keep-tag keep` in `restic-backup` honors the tag):

```sh
just restic-snapshots                          # pick the ID
just restic tag --add keep --add my-label ID   # note: retags under a NEW ID
# .env: RESTIC_RESTORE_SNAPSHOT=<new ID>
just ship                                       # deploy the selector
oasis rofl machine restart --wipe-storage -y    # fresh volume, restore runs
# verify, then .env: RESTIC_RESTORE_SNAPSHOT=latest, and `just ship` again.
# A leftover ID makes every future recovery repeat the rollback.
```

The selector fails closed: an ID that matches no snapshot aborts the boot with
`FATAL: RESTIC_RESTORE_SNAPSHOT=... matches no snapshot` instead of silently
restoring `latest`.

### Verifying it works

1. Deploy, wait until `just logs` shows Hermes long-polling Telegram.
2. Send the bot a message or two so there's a non-trivial session on disk.
3. Wait one `BACKUP_INTERVAL`, then `just restic-snapshots` — a new snapshot
   should appear, with host `rofl` and no `restore-unverified` tag.
4. `oasis rofl machine remove` to destroy the lease.
5. `just deploy` to spawn a new machine, `just logs` to follow.
6. The new bot session continues prior conversations — state restored.

The `restore-unverified` tag is worth watching for: it means `restic-backup`
gave up waiting for the restore sentinel and snapshotted anyway, so that
snapshot may hold a partial tree.

The bucket itself is opaque: restic stores content-addressed encrypted blobs
under `data/`, so nothing about your filenames or directory layout is visible
to Cloudflare.

### Debugging

- List restore points / contents: `just restic-snapshots`, `just restic ls latest`.
- Read backup logs: `docker compose logs restic-backup` (locally) or
  `just logs` (on ROFL).
- Confirm a secret is present in the on-chain manifest:
  `oasis rofl secret get R2_ACCESS_KEY_ID`
- If restore fails on boot, `restic-restore` exits non-zero and publishes no
  sentinel, so the waiters keep waiting. Check `docker compose logs
  restic-restore`. It fails **closed** on purpose: `restic snapshots` exits
  non-zero for an absent repository, wrong credentials and network failure
  alike, so "cannot reach the repository" is never read as "nothing to restore".
- Reconstruct the boot ordering after the fact — ROFL only captures stdout from
  some containers, so each service also appends to a trace file on the volume:
  `just restic dump latest /opt/data/.boot-trace`
- A stale lock (the machine was killed mid-backup) does not block the next
  backup, but does block `forget --prune`. `restic-backup` clears it with
  `restic unlock --remove-all` before each retention run.

### Operational notes

- **Single-writer assumption.** Only one ROFL machine should back up to a given
  repository at a time. Concurrent writers will fight and corrupt Hermes session
  files (Hermes itself warns against this). It is also what makes
  `restic unlock --remove-all` safe here.
- **The host is pinned to `rofl` deliberately.** restic groups retention by
  `(host, paths)`, and every container gets a random hostname. Without the pin,
  each run forms its own retention group and `restic forget` deletes **nothing**
  while still exiting 0 — measured: `--keep-last 2` left all 6 snapshots.
- **Backup staleness is alerted on, from two places, and it needs both.**
  `backup-watchdog` runs in the enclave and messages Telegram when the newest
  successful backup is older than `BACKUP_STALE_AFTER` (default 3h). It is
  gated on *nothing*: the 17-hour silent gap happened because `restic-backup`
  was stuck in `wait_for_restore` before its backup loop ever ran, and
  `cache-prune` and `db-snapshot` block on that same sentinel — a watchdog
  sharing the dependency it watches would have been just as stuck.

  That covers "machine up, backups not happening". It cannot cover "machine
  gone", because it dies with the machine. For that, run `just backup-check`
  somewhere else — it exits 1 when the newest snapshot is older than
  `MAX_AGE_HOURS` (default 3) and 2 when the repository is unreachable, so it
  drops straight into cron or launchd:

  ```sh
  */30 * * * * cd /path/to/repo && just backup-check || notify-me
  ```
- **Encryption key rotation** is out of scope. restic supports adding a second
  key to a repository (`restic key add`), which is the starting point if you
  need it — but the existing snapshots stay encrypted to the master key either
  way. Document and script this when you actually need it.
- **Caches accumulate.** If skills install large dependencies (npm,
  Python venvs), check the exclude list above — extend it if a new tool
  introduces a cache pattern that should never be backed up.

## Dashboard access (wallet gateway)

`compose.yaml` exposes two web dashboards — but never directly. Three services
cooperate (`compose-openrouter.yaml` has none):

- `hermes-dashboard` — the stock Hermes dashboard, run with `--insecure` (its
  own auth gate **off**) on `0.0.0.0:9119`. It has **no `ports:` entry**, so it
  is only reachable on the internal compose network, never from outside.
- `hermes-security-dashboard` — the [security findings
  dashboard](https://github.com/rube-de/hermes-security-dashboard) on
  `0.0.0.0:3000`, also with **no `ports:` entry**. Its image bakes
  `BASE_PATH=/security`, so it answers only under that prefix. See "Security
  dashboard" below.
- `wallet-gateway` — [a SIWE reverse
  proxy](https://github.com/rube-de/hermes-wallet-gateway) published on port
  8080. It verifies an Ethereum wallet signature (Sign-In-With-Ethereum), checks
  the address against an allowlist, issues an HMAC-signed session cookie, and
  only then proxies. It **path-routes** by URL prefix: `/security/*` to the
  security dashboard, everything else to `hermes-dashboard`. One login covers
  both (same origin). It is the sole inbound perimeter.

Serving these dashboards without their own login is safe **only** because of
that shape — no published port of their own, gateway in front. Don't add a
`ports:` entry to either dashboard.

### Gateway settings

Baked into `compose.yaml` (part of the attested bundle, not secret):

| Var | Value | Meaning |
| --- | --- | --- |
| `HERMES_TARGET` | `http://hermes-dashboard:9119` | catch-all upstream (unmatched paths) |
| `GATEWAY_ROUTES` | `{"/security":"http://hermes-security-dashboard:3000"}` | path-prefix → upstream routing table (JSON) |
| `WALLET_CHAIN_ID` | `1` | chain SIWE verifies against |
| `WALLET_SESSION_TTL` | `43200` | session lifetime in seconds (12h) |
| `WALLET_STATEMENT` | `Sign in to the Hermes dashboard.` | text shown in the wallet sign prompt |
| `PORT` | `8080` | gateway listen port |

Injected as **ROFL secrets** (`.env` → `just set-secrets`):

| Secret | Meaning |
| --- | --- |
| `WALLET_WHITELIST` | comma-separated `0x` addresses allowed to log in |
| `WALLET_SESSION_SECRET` | HMAC key for session cookies (`openssl rand -hex 32`) |
| `WALLET_DOMAIN` | public host(s) SIWE binds to — the ROFL proxy domain |

The gateway accepts more knobs (`WALLET_WC_PROJECT_ID` for WalletConnect/QR,
`COOKIE_SECURE`, …) — see its repo, and add them to the compose `environment:`
or as secrets if you need them.

### The `WALLET_DOMAIN` chicken-and-egg

SIWE binds each login to a specific domain, but you don't learn the ROFL proxy
host until the machine exists. So bringup is two-phase:

1. Deploy with `WALLET_DOMAIN` empty (or a placeholder). The gate comes up, but
   domain binding isn't final, so logins won't complete yet.
2. `just show` → read the `Domain:` line under `Proxy:` (e.g.
   `m1583.test-proxy-b.rofl.app`).
3. Put that host in `WALLET_DOMAIN` in `.env`, then re-provision it — no rebuild
   needed, since only a secret changed:

   ```sh
   just set-secrets     # re-imports .env (encrypts WALLET_DOMAIN on-chain)
   just update          # republishes the manifest
   just restart         # machine re-provisions secrets as container env
   ```

4. Open `https://<that-domain>/`, connect your wallet, sign the statement — and
   you're in. To revoke someone, drop their address from `WALLET_WHITELIST` and
   repeat step 3; it blocks new logins immediately (existing cookies last until
   they expire — at most `WALLET_SESSION_TTL`).

### Shared `/opt/data`

`hermes-dashboard` and `hermes` both mount the `hermes-data` volume, so the
dashboard sees the same agent state the Telegram bot uses, and edits made there
are backed up like everything else. Both now block on the same restore sentinel as
the backup services, wrapped around the image's own entrypoint so the image CMD
still reaches it untouched. That matters most for the security dashboard: it
rebuilds its live DB from `security/snapshot.db` at boot and writes that snapshot
back every `HERMES_SNAPSHOT_INTERVAL`, so an ungated start on a recovering volume
would overwrite the restored findings with an empty database.

### Security dashboard (`/security`)

A separate [security findings
dashboard](https://github.com/rube-de/hermes-security-dashboard) rides behind
the same gate at `https://<domain>/security`. The `wallet-gateway` path-routes
`/security/*` to it and forwards the path untouched — which is why it runs the
`:latest-security` image tag (built with `BASE_PATH=/security` baked in). One
SIWE login covers both dashboards; they share the gateway's origin and session.

**Two trust surfaces.** The read UI (what you see in the browser) is wallet-gated
like the Hermes dashboard. The **write API** — the endpoints a security-review
cron pushes findings to — is guarded separately by a bearer token,
`HERMES_API_TOKEN` (a ROFL secret). Set it: left empty, the dashboard accepts
unauthenticated writes (and logs a loud warning). A logged-in human can't forge
findings, because the SIWE session doesn't carry that token.

**The cron pushes internally, not through the gate.** The gateway rejects any
request without a SIWE session, so a headless cron can't push through port 8080.
It must reach the dashboard directly on the compose network, and include the
`/security` prefix (the base-path image 404s at the root):

```
POST http://hermes-security-dashboard:3000/security/api/repos
Authorization: Bearer $HERMES_API_TOKEN
```

So the security-review job has to run on this machine's compose network (as a
service here, or otherwise on the same Docker network) — not from outside.

**Durability.** The dashboard keeps its SQLite DB in WAL mode under
`security/live/` (excluded from sync) and emits a consistent `VACUUM INTO`
snapshot at `security/snapshot.db` every `HERMES_SNAPSHOT_INTERVAL` seconds and
on shutdown. Only that snapshot is backed up; on a fresh machine the dashboard
restores the live DB from it before serving. `db-snapshot` deliberately skips
both paths — `security/live/` because it is the hot DB, and
`security/snapshot.db` because copying it would be snapshotting a snapshot.
See "Persistent storage".

## References

- Hermes Docker — <https://hermes-agent.nousresearch.com/docs/user-guide/docker>
- Hermes providers — <https://hermes-agent.nousresearch.com/docs/integrations/providers>
- ROFL quickstart — <https://docs.oasis.io/build/rofl/quickstart/>
- ROFL containerize rules — <https://docs.oasis.io/build/rofl/workflow/containerize-app/>
- Cloudflare R2 S3 API — <https://developers.cloudflare.com/r2/api/s3/api/>
- restic — <https://restic.readthedocs.io/>
- Wallet gateway (SIWE) — <https://github.com/rube-de/hermes-wallet-gateway>
- Security dashboard — <https://github.com/rube-de/hermes-security-dashboard>
