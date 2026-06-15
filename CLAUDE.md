# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A macOS tool for running coding agents (Claude Code, OpenCode, ...) inside isolated Apple Container containers (Debian bookworm). Requires Apple Silicon and macOS 26+. Containers get full `--dangerously-skip-permissions` access without touching the host. The host directory you invoke `rp` from is bind-mounted to `/workspace` inside the container.

The project is named **robo-pen**. The wrapper command is **`rp`**.

## Commands

The `rp` script wraps `just` recipes so you can invoke them from any directory. The current working directory becomes the container's `/workspace` mount; the container name defaults to `rp-<agent>-<basename of cwd>`. An explicit `<name>` arg overrides the default.

```bash
# One-time setup (run from anywhere)
rp setup               # installs Apple Container + jq + just, starts service
rp build-host          # cross-build the host rp-fuse binary for `rp lint`
rp build               # build base + default image
rp rebuild             # build without cache

# Daily use — cwd-anchored
cd ~/my-existing-repo
rp run                  # auto-creates container rp-<agent>-<basename>, runs the agent
rp run --gated          # permission-prompted run mode
rp shell                # bash shell inside the cwd container
rp login                # run the agent's login flow (e.g. Claude subscription auth)
rp stop                 # pause container
rp start                # resume container
rp destroy              # remove container (workspace files untouched)

# Explicit name still works (overrides cwd default)
rp create my-project
rp run my-project "prompt"
rp run --gated my-project

# Info
rp list                 # all rp-managed containers, status, workspace path
rp stats                # CPU/memory usage
rp logs                 # container log output
rp lint                 # validate .rp/{shadow,config.yaml,agents/}

# File transfer (for paths outside /workspace)
rp cp-to <name> <src> <dest>
rp cp-from <name> <src> <dest>
```

## Architecture

```
Dockerfile.base         — rp-base: minimal debian + fuse3 + rp-fuse + rp-init.sh + coder user
Dockerfile              — robo-pen-default (FROM rp-base) + Node 22 + Python/uv + R + DuckDB + just; no agent
Justfile                — recipes; container prefix = "rp-" + agent + "-"; bind = invocation_directory()
rp                      — wrapper that invokes just WITHOUT --working-directory, so just sees the caller's cwd
rp-fuse/                — Go: FUSE driver, lint, config + profile parsers; tests/ for integration sh
scripts/
  build-project-image.sh — composes the per-project image (rp overlay onto image: ref or .rp/Dockerfile output)
  resolve-create-args.sh — translates .rp/config.yaml + agent profile into `container create` flags
agent.profiles/<name>/   — built-in agent profile bundles (claude-code is the only one in v1)
  manifest.yaml         — schema in rp-fuse/profile.go (env, files, entrypoints, instructions_dst)
  install.sh, run.sh, run-gated.sh, login.sh — lifecycle scripts COPYed into the overlay
  settings/             — files baked into the image at manifest's files[].dst
  instructions.md       — agent-specific fragment for the composed CLAUDE.md / AGENTS.md
config/
  00-container.md       — agent-agnostic container fundamentals (baked into rp-base)
  10-toolchain-default.md — toolchain table for the default image (baked into robo-pen-default)
  rp-init.sh            — baked into the image at /usr/local/bin/rp-init.sh; PID 1; execs rp-fuse
.env.example            — template for ANTHROPIC_API_KEY (also forwarded based on profile manifest's env: list)
.rp.example/            — template for .rp/ (config.yaml + shadow)
docs/adr/               — design decisions (ADR-0001..0007)
```

**Key design points:**

- Containers are named `rp-<agent>-<basename>` (e.g., `cd ~/foo && rp run` with default agent → container `rp-claude-code-foo`). Same workspace can host parallel containers per agent.
- The host dir where `rp` is invoked is bind-mounted to **`/workspace-real`** in the container. `rp-fuse` then mounts a rule-aware filesystem at `/workspace`, which is what the user/Claude sees. See `CONTEXT.md` for vocabulary and `docs/adr/0001-custom-go-fuse-for-workspace-shadowing.md` for the design rationale.
- Container name and bind-mount source both come from `invocation_directory()` (a `just` builtin returning caller's cwd before `just` chdirs to the justfile dir). The Justfile resolves the agent at every invocation via `rp-fuse config field agent` against the workspace's `.rp/config.yaml`.
- Each container records its mount path as a label (`rp.host_path=<absolute path>`). Interactive recipes verify this label matches the current cwd to prevent collisions — if `rp-claude-code-foo` exists but was created from `~/work/foo`, running `rp run` from `~/personal/foo` aborts with a clear error.
- The `_ensure` helper recipe is called as a dependency by `shell`/`login`/`run`: it auto-creates the container if missing, runs the collision check, and starts it if stopped.
- Auth is per-agent: the profile's `manifest.env` declares which host env vars to forward (e.g. `ANTHROPIC_API_KEY` for claude-code); the profile's `login.sh` runs the subscription / interactive auth flow if it exists.
- `rp create <name> -- <container-args>` passes extra `container` CLI flags (e.g., extra volume mounts, port bindings).
- `rp` defaults to `~/repos/robo-pen`; override with `ROBO_PEN_DIR`.
- `build-base` builds the foundational `rp-base` image; `build` builds the default `robo-pen-default` image (FROM rp-base). Both use `{{justfile_directory()}}` as the build context so they work regardless of where `rp` was invoked. `rebuild` no-caches both layers.
- **Per-project images** (ADR-0006 + ADR-0007): every workspace goes through the overlay. `scripts/build-project-image.sh` reads `.rp/config.yaml` for `image:` / `build:` (defaults to `robo-pen-default`) and the agent profile (defaults to `claude-code`), then composes a final image tagged `<container-name>:latest-rp`. The overlay installs fuse3, validates/creates the configured user, mkdir's `/var/lib/rp` at 0700, COPYs `rp-fuse` + `rp-init.sh` from the locally-tagged `rp-base`, COPYs the agent profile's install.sh / settings / instructions / run scripts, runs install.sh as the configured user, and concatenates `/etc/rp/instructions/*.md` into the agent's `instructions_dst`.
- **Agent profile lookup** (ADR-0007): workspace `.rp/agents/<name>/manifest.yaml` overrides repo `agent.profiles/<name>/manifest.yaml`. A directory without `manifest.yaml` is treated as not-present; `rp lint` warns on partial workspace overrides.
- **Edit-config cycle**: changes to `.rp/config.yaml` (agent, image, user, resources, fuse.cache) take effect only at container CREATE time. To pick them up, `rp destroy && rp run` (or `create`). `.rp/shadow` is re-read on every `rp start`, so for shadow-rule-only changes a `rp stop && rp start` suffices.
- **Debug toggle**: `RP_DEBUG=1 rp create <name>` forwards the env var into the container; `rp-init.sh` then launches `rp-fuse --debug` for verbose FUSE logging. `RP_DEBUG=1 rp build` (via `rp create`) also prints the generated overlay Dockerfile.
- **Runtime knobs** (ADR-0006 v1 Tier-1): `.rp/config.yaml` supports `resources.memory` (string like `4G`), `resources.cpus` (positive int), and `fuse.cache` (seconds float). Read by `scripts/resolve-create-args.sh` at create time; memory/cpus become `container create --memory`/`--cpus` flags, fuse.cache is forwarded as `-e RP_CACHE=…` and picked up by `rp-init.sh`. `rp lint` validates all of them.
- **Shadow filtering via `.rp/shadow`** (`rp-fuse` driven, launched by `rp-init.sh` at PID 1): containers are created with `--cap-add SYS_ADMIN --user 0`. The init script execs `rp-fuse --backing /workspace-real --shadow /var/lib/rp/shadow --mount /workspace --rules /workspace-real/.rp/shadow`. `.rp/shadow` uses a strict subset of gitignore syntax (one pattern per line; `*`, `**`, `?`, `[…]`, leading `/` or any mid-`/` anchors to root, trailing `/` for directory-only; no negation). For every path that matches a pattern:
  - Host's matching content is INVISIBLE in the container (`stat` returns ENOENT).
  - Container creates/writes/deletes go to `/var/lib/rp/shadow/<rel-path>` — NEVER to the host bind.
  - Build scripts that `rm -rf node_modules && reinstall` are fully contained: the host filesystem is never touched.
  - The shadow store survives `rp stop`/`start`; wiped on `rp destroy`.
- Paths NOT matched by `.rp/shadow` pass through `rp-fuse` to `/workspace-real`. Edits to source files propagate to the host as expected.
- Init runs as root (UID 0) for `/dev/fuse` access; `container exec -u coder` on all interactive recipes (`shell`, `login`, `run`) so user sessions run as `coder`. `rp-fuse` mounts with `allow_other`, and `/etc/fuse.conf` has `user_allow_other` enabled in the image.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for this repo. Skills use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo — one `CONTEXT.md` + `docs/adr/` at repo root (produced lazily by `/grill-with-docs`). See `docs/agents/domain.md`.
