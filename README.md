# hermes-rofl-security

Hermes Agent running inside an Oasis ROFL TDX enclave. Agent state (`/opt/data`)
and credentials live in the TEE; prompts and tool calls still exit to whichever
inference provider you wire up (Z.AI's GLM coding plan, OpenRouter, …).

## What's in here

| File                     | Origin              | Purpose                                                      |
| ------------------------ | ------------------- | ------------------------------------------------------------ |
| `rofl.yaml`              | `oasis rofl init`   | TEE manifest. Resources tuned to ~playground_short.          |
| `compose.yaml`           | edited after init   | Default deployment — Hermes against Z.AI's GLM coding plan.  |
| `compose-openrouter.yaml`| this repo           | Alternative deployment — Hermes against OpenRouter.          |
| `.env.example`           | this repo           | Names of the secrets you must `secret import`.               |
| `justfile`               | this repo           | Wrappers around the `oasis rofl ...` sequence.               |

Both compose files share the same shape: pinned Hermes image, a small `command:`
shell wrapper that overwrites `/opt/data/config.yaml` with the right `model:`
block on every boot, then `exec hermes gateway run`. We overwrite the config
because the image's entrypoint copies a default template
(`cli-config.yaml.example`) that points at OpenRouter+Claude when no
`config.yaml` exists — that default would otherwise win over env-var overrides
for the gateway.

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

The model is hard-coded in each compose's inline config block, not in `.env`.
This is deliberate: the model becomes part of the attested bundle, so anyone
verifying the enclave can see which model it serves.

- `compose.yaml`: `default: glm-5-turbo`. Z.AI's coding plan also exposes
  `glm-5.1`, `glm-5`, `glm-4.7`, `glm-4.5-air` — swap the literal string in
  the `cat <<CFG` heredoc. See <https://docs.z.ai/devpack/tool/others>.
- `compose-openrouter.yaml`: `default: anthropic/claude-opus-4.6` (upstream
  Hermes' own example default). For a cheaper steady-state, swap to e.g.
  `anthropic/claude-haiku-4.6` or `google/gemini-3-flash-preview`. See
  <https://openrouter.ai/models>.

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
- **No exposed ports.** Telegram is outbound long-polling; the OpenAI-compatible
  Gateway API (port 8642) is intentionally not published. Adding it requires a
  ROFL ingress design that's not in this scaffold.
- **Image is pinned.** Bumping Hermes = resolve the new digest with
  `docker buildx imagetools inspect docker.io/nousresearch/hermes-agent:main`,
  edit the `image:` line in both compose files, rebuild, update, redeploy.
- **Switching compose files rotates the enclave ID.** Any client that pinned
  the previous attestation will need to re-trust the new identity.

## References

- Hermes Docker — <https://hermes-agent.nousresearch.com/docs/user-guide/docker>
- Hermes providers — <https://hermes-agent.nousresearch.com/docs/integrations/providers>
- ROFL quickstart — <https://docs.oasis.io/build/rofl/quickstart/>
- ROFL containerize rules — <https://docs.oasis.io/build/rofl/workflow/containerize-app/>
