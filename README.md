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
| `compose.yaml`           | edited after init   | Default deployment — GLM + Akave + wallet-gated dashboard.   |
| `compose-openrouter.yaml`| this repo           | Alternative deployment — Hermes against OpenRouter.          |
| `.env.example`           | this repo           | Names of the secrets you must `secret import`.               |
| `justfile`               | this repo           | Wrappers around the `oasis rofl ...` sequence.               |

Both compose files share a core shape: the pinned Hermes image plus two rclone
sidecars (see "Persistent storage" below) and a small `command:` wrapper. On
the very first boot — when no sentinel marker (`/opt/data/.compose-initialized`)
exists yet — the wrapper writes a default `config.yaml` from the heredoc and
drops the marker. On every subsequent boot it leaves `config.yaml` alone, so
whatever the user (or Hermes itself) has put there — added auxiliary
providers, swapped the model, configured skills — is the source of truth.

They differ in one way: `compose.yaml` additionally runs a `hermes-dashboard`
service with a `wallet-gateway` in front of it (see "Dashboard access" below),
while `compose-openrouter.yaml` is Telegram-only. Switching to OpenRouter as-is
therefore drops the web dashboard unless you port those two services across.

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
at runtime persist through Akave sync and survive machine replacement. So:

- Pick the right default in compose if you don't want to log in and edit
  things after first deploy.
- For everything after that, change the model by editing
  `/opt/data/config.yaml` directly in the running container (or via
  whatever Hermes UI you use) — the change will be synced to Akave on the
  next cycle.
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
  a valid SIWE session from an allowlisted address. The dashboard (9119) and
  Hermes' OpenAI-compatible Gateway API (8642) stay unpublished; the gateway is
  the sole perimeter. `compose-openrouter.yaml` publishes nothing — Telegram is
  outbound long-polling.
- **Pin images by digest for production.** The two `rclone` sidecars are already
  pinned (`rclone:1.69@sha256:…`), but the app images in `compose.yaml` —
  `hermes`, `hermes-dashboard`, and the `wallet-gateway` — track floating
  `:latest` tags for convenience. That's fine while iterating, but **in
  production pin each to a digest instead of a bare `:latest`**: the enclave
  identity is derived from the exact bundle, so a floating tag means the attested
  image can change under you and the build isn't reproducible. Resolve a digest
  with `docker buildx imagetools inspect docker.io/nousresearch/hermes-agent:latest`
  and replace `:latest` with `@sha256:…` (see `compose-openrouter.yaml`, which
  pins Hermes this way). Then rebuild, update, redeploy — which rotates the
  enclave ID.
- **Switching compose files rotates the enclave ID.** Any client that pinned
  the previous attestation will need to re-trust the new identity.

## Persistent storage (Akave + rclone)

ROFL `disk-persistent` storage is leased to a specific machine. When that lease
ends (funding runs out, you destroy the machine, the scheduler relocates it),
the disk goes with it. To survive that, Hermes's `/opt/data` is mirrored to
[Akave Cloud](https://console.akave.com/) — an S3-compatible, Filecoin-backed
bucket — through two rclone sidecars defined in `compose.yaml`:

- `rclone-restore` — one-shot init container. On boot, pulls everything from
  the encrypted bucket into the local `hermes-data` volume. `hermes` waits
  on this via `depends_on: condition: service_completed_successfully` — it
  doesn't start serving until restore completes.
- `rclone-sync` — long-running sidecar. Every `SYNC_INTERVAL` seconds
  (default 300), syncs the local volume back to the bucket. On `SIGTERM` it
  performs one final flush before exiting, so `docker compose down` doesn't
  lose unsynced writes.

Encryption is client-side via `rclone crypt`. Akave only ever sees ciphertext
— filenames and contents are encrypted with a passphrase + salt you generate
locally and inject as ROFL secrets. **If you lose both the passphrase and the
salt, every file in the bucket is unrecoverable.**

Hermes runs as user `hermes` (UID 10000) whose HOME is `/opt/data`, so any
CLI tool it invokes (codex, claude-code, …) lands its config and OAuth
tokens under `/opt/data/.codex/`, `/opt/data/.claude/`, etc. — all of that
is inside the synced volume. Nothing extra to wire up for auxiliary
providers' auth state.

`config.yaml` is full Hermes configuration (model selection, auxiliary
providers added via OAuth, skill settings, hooks, channel prompts, …) —
all of that survives machine replacement via sync. The compose only writes
to `config.yaml` on the very first boot, gated by the
`/opt/data/.compose-initialized` sentinel file. Once that marker exists
(which happens within the first few seconds of the initial deploy and is
itself synced to Akave), subsequent boots leave `config.yaml` entirely
alone — the user/agent is the sole writer.

The following are deliberately excluded from sync (regenerable, or owned
by the running container):

- `logs/**` — runtime logs, unbounded growth, no restore value
- `.cache/**`, `.npm/**`, `node_modules/**` — package/tool caches
- `__pycache__/**`, `*.pyc`, `.pytest_cache/**`, `.mypy_cache/**`,
  `.ruff_cache/**`, `.tox/**`, `.venv/**` — Python build artifacts

  (Patterns are intentionally *unanchored* — `.cache/**`, not `**/.cache/**`.
  Hermes's HOME is the sync root `/opt/data`, so its caches sit at the root;
  rclone's `**/` prefix requires a parent directory and would miss them.)

There's also a `/opt/data/vault/` directory created on Hermes boot — drop any
file you want preserved across machine replacement into it (or anywhere
under `/opt/data/` except the excluded paths).

### One-time setup

1. Create a bucket and an access key pair at <https://console.akave.com/>.
   The console gives you a per-credential endpoint URL — copy that too.

2. Generate the crypt passphrase and salt locally. Use long random values;
   they're the only thing standing between Akave and your plaintext:

   ```sh
   just obscure "$(openssl rand -base64 48)"   # password
   just obscure "$(openssl rand -base64 32)"   # salt
   ```

   Both lines print an obscured string. Copy each into the matching
   `RCLONE_CRYPT_*` slot in `.env`. **Save the original (un-obscured) values
   in a password manager** — you cannot recover them from the obscured form
   and you'll need them again if you ever restore outside this stack.

3. Fill in the rest of `.env` (Akave + existing Hermes secrets), then push
   the whole bundle on-chain and republish the manifest:

   ```sh
   cp .env.example .env       # then edit
   just set-secrets           # = oasis rofl secret import --force .env
   just update                # publishes the updated manifest
   ```

### Rotating a single secret

Reading a value into the CLI via file avoids putting it in shell history:

```sh
printf '%s' "$NEW_VALUE" > /tmp/secret && \
  oasis rofl secret set AKAVE_SECRET_KEY /tmp/secret && \
  rm /tmp/secret
just update
```

Or rotate the whole bundle: edit `.env`, `just set-secrets && just update`.

### Bootstrapping from existing local data

If you already have a populated Hermes data dir you want to seed the bucket
with, run rclone locally once before the first ROFL deploy:

```sh
# With the same env vars set locally (export AKAVE_*, RCLONE_CRYPT_*)
docker run --rm \
  -v "$HOME/.hermes:/sync" \
  -e RCLONE_CONFIG_AKAVE_TYPE=s3 -e RCLONE_CONFIG_AKAVE_PROVIDER=Other \
  -e RCLONE_CONFIG_AKAVE_REGION=akave-network \
  -e RCLONE_CONFIG_AKAVE_ENDPOINT="$AKAVE_ENDPOINT" \
  -e RCLONE_CONFIG_AKAVE_ACCESS_KEY_ID="$AKAVE_ACCESS_KEY" \
  -e RCLONE_CONFIG_AKAVE_SECRET_ACCESS_KEY="$AKAVE_SECRET_KEY" \
  -e RCLONE_CONFIG_AKAVE_FORCE_PATH_STYLE=true \
  -e RCLONE_CONFIG_CRYPT_TYPE=crypt \
  -e RCLONE_CONFIG_CRYPT_REMOTE="akave:$AKAVE_BUCKET" \
  -e RCLONE_CONFIG_CRYPT_FILENAME_ENCRYPTION=standard \
  -e RCLONE_CONFIG_CRYPT_PASSWORD="$RCLONE_CRYPT_PASSWORD" \
  -e RCLONE_CONFIG_CRYPT_PASSWORD2="$RCLONE_CRYPT_SALT" \
  rclone/rclone:1.69 sync /sync crypt: \
    --exclude=config.yaml --exclude=logs/**
```

### Verifying it works

1. Deploy, wait until `just logs` shows Hermes long-polling Telegram.
2. Send the bot a message or two so there's a non-trivial session on disk.
3. Wait one `SYNC_INTERVAL`, then `just inspect-bucket` — you should see
   filenames (decrypted via the sidecar's crypt remote).
4. `oasis rofl machine remove` to destroy the lease.
5. `just deploy` to spawn a new machine, `just logs` to follow.
6. The new bot session continues prior conversations — state restored.

To verify encryption directly, read the bucket via the underlying S3
remote (no crypt unwrapping):

```sh
docker compose exec rclone-sync rclone lsf akave:$AKAVE_BUCKET
```

Filenames here are ciphertext (base32-encoded encrypted blobs).

### Debugging

- Inspect bucket contents (decrypted view):
  `just inspect-bucket`
- Read sidecar logs: `docker compose logs rclone-sync` (locally) or
  `just logs` (on ROFL).
- Confirm a secret is present in the on-chain manifest:
  `oasis rofl secret get AKAVE_ACCESS_KEY`
- If restore fails on boot, the hermes service won't start. Check
  `docker compose logs rclone-restore` for the failing rclone command.

### Operational notes

- **Single-writer assumption.** Only one ROFL machine should be syncing to
  a given bucket at a time. Concurrent writers will fight and corrupt
  Hermes session files (Hermes itself warns against this).
- **Encryption key rotation** is out of scope. If you need to rotate the
  crypt password/salt, the procedure is: stop the stack, run rclone with
  the old crypt config to download to a temp dir, generate new keys,
  re-upload with the new crypt config. Document and script this when you
  actually need it.
- **Caches accumulate.** If skills install large dependencies (npm,
  Python venvs), check the exclude list above — extend it if a new tool
  introduces a cache pattern that should never be synced.

## Dashboard access (wallet gateway)

`compose.yaml` exposes Hermes' web dashboard — but never directly. Two services
cooperate (`compose-openrouter.yaml` has neither):

- `hermes-dashboard` — the stock Hermes dashboard, run with `--insecure` (its
  own auth gate **off**) on `0.0.0.0:9119`. It has **no `ports:` entry**, so it
  is only reachable on the internal compose network, never from outside.
- `wallet-gateway` — [a SIWE reverse
  proxy](https://github.com/rube-de/hermes-wallet-gateway) published on port
  8080. It verifies an Ethereum wallet signature (Sign-In-With-Ethereum), checks
  the address against an allowlist, issues an HMAC-signed session cookie, and
  only then proxies traffic to `hermes-dashboard`. It is the sole inbound
  perimeter.

Running the dashboard `--insecure` is safe **only** because of that shape — no
published port of its own, gateway in front. Don't add a `ports:` entry to
`hermes-dashboard`.

### Gateway settings

Baked into `compose.yaml` (part of the attested bundle, not secret):

| Var | Value | Meaning |
| --- | --- | --- |
| `HERMES_TARGET` | `http://hermes-dashboard:9119` | upstream the gateway proxies to |
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
sync to Akave like everything else. Note: only `hermes` waits on
`rclone-restore`; the dashboard may start against a not-yet-restored
`/opt/data`, but it shares the live volume and picks state up as restore lands.

## References

- Hermes Docker — <https://hermes-agent.nousresearch.com/docs/user-guide/docker>
- Hermes providers — <https://hermes-agent.nousresearch.com/docs/integrations/providers>
- ROFL quickstart — <https://docs.oasis.io/build/rofl/quickstart/>
- ROFL containerize rules — <https://docs.oasis.io/build/rofl/workflow/containerize-app/>
- Akave Cloud / O3 — <https://docs.akave.xyz/>
- rclone crypt — <https://rclone.org/crypt/>
- Wallet gateway (SIWE) — <https://github.com/rube-de/hermes-wallet-gateway>
