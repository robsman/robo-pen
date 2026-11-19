# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A macOS tool for running coding agents (Claude Code, OpenCode, ...) inside isolated Apple Container containers (Debian trixie). Requires Apple Silicon and macOS 26+. Containers get full `--dangerously-skip-permissions` access without touching the host. The host directory you invoke `rp` from is bind-mounted 1:1 inside the container — same path inside and outside.

The project is named **robo-pen**. The wrapper command is **`rp`**.

## Commands

The `rp` script wraps `just` recipes so you can invoke them from any directory. The current working directory is bind-mounted 1:1 inside the container — the workspace path is the same inside and outside. The container name defaults to `rp-<agent>-<repo>-<worktree>`, shortened to `rp-<agent>-<repo>` at a repo's top level (ADR-0021). An explicit `<name>` arg overrides the default.

```bash
# One-time setup (run from anywhere)
rp setup               # installs Apple Container + jq + just, starts service
rp build-host          # cross-build the host rp-fuse binary for `rp lint`
rp build               # build base + default image
rp rebuild             # build without cache

# Daily use — cwd-anchored
cd ~/my-existing-repo
rp run                  # auto-creates container rp-<agent>-<repo>[-<worktree>], runs the agent
rp run --gated          # permission-prompted run mode
rp shell                # bash shell inside the cwd container
rp login                # run the agent's login flow (e.g. Claude subscription auth)
rp stop                 # pause container
rp start                # resume container
rp destroy              # remove container (workspace files untouched)

# Explicit name (--name overrides the cwd-based default)
rp create --name my-project
rp run --name my-project -- "prompt"
rp run --name my-project -- --gated

# Multi-workspace (each PATH is FUSE-shadowed independently). Append :ro
# for read-only. Container name is repo-scoped from the first PATH.
rp create . /Users/me/shared-libs            # cwd + shared-libs, name from cwd's repo
rp create /a /b:ro                           # /a writable, /b read-only; name = a

# Info
rp list                 # all rp-managed containers, status, workspace path
rp stats                # CPU/memory usage
rp logs                 # container log output
rp lint                 # validate .rp/{shadow,config.yaml,agents/}

# File transfer (for paths outside the workspace bind)
rp cp-to <name> <src> <dest>
rp cp-from <name> <src> <dest>
```

## Architecture

```
Dockerfile.system       — rp-system: minimal debian + fuse3 + rp-fuse + rp-init.sh + coder user
Dockerfile.default      — rp-default: standalone (not FROM rp-system) + git/curl/build-essential only; no language runtime, no agent
Justfile                — recipes; container prefix = "rp-" + agent + "-"; bind = invocation_directory()
rp                      — wrapper that invokes just WITHOUT --working-directory, so just sees the caller's cwd
rp-fuse/                — Go: FUSE driver, lint, config + profile parsers; tests/ for integration sh
scripts/
  build-project-image.sh — composes the per-project image (rp overlay onto image: ref or .rp/Dockerfile output)
  resolve-create-args.sh — translates .rp/config.yaml + agent profile into `container create` flags
  resolve-workspace-name.sh — repo-scoped default container name + repo slug (ADR-0021)
agent.profiles/<name>/   — built-in agent profile bundles (claude-code is the only one in v1)
  manifest.yaml         — schema in rp-fuse/profile.go (env, files, entrypoints, instructions_dst)
  install.sh, run.sh, run-gated.sh, login.sh — lifecycle scripts COPYed into the overlay
  settings/             — files baked into the image at manifest's files[].dst
  instructions.md       — agent-specific fragment for the composed CLAUDE.md / AGENTS.md
config/
  00-container.md       — agent-agnostic container fundamentals (baked into rp-system)
  10-toolchain-default.md — toolchain table for the minimal default image (baked into rp-default)
  rp-init.sh            — baked into the image at /usr/local/bin/rp-init.sh; PID 1; execs rp-fuse
.env.example            — template for ANTHROPIC_API_KEY (also forwarded based on profile manifest's env: list)
.rp.example/            — template for .rp/ (config.yaml + shadow)
docs/adr/               — design decisions (ADR-0001..0007)
```

**Key design points:**

- Containers are named `rp-<agent>-<repo>[-<worktree>]` (ADR-0021). `cd ~/foo && rp run` at a repo top level → `rp-claude-code-foo`; the worktree `~/foo/main` of repo `foo` → `rp-claude-code-foo-main`. Repo identity comes from `git rev-parse --git-common-dir`, so sibling worktrees of different repos never collide. A directory outside any repo keeps basename naming. Same workspace can host parallel containers per agent.
- **Agent volumes are keyed by repo** (ADR-0014 + ADR-0021): backing dirs live at `~/.local/share/robo-pen/volumes/rp-<agent>-<repo>/<volume>/`, so every worktree of one repo shares one `~/.claude` and one `rp login`. The key ignores `--name`; `RP_VOLUME_KEY` overrides it.
- The host dir where `rp` is invoked is bind-mounted 1:1 inside the container (same path inside and outside). `rp-init.sh` discovers the workspace path via `RP_WORKSPACE` env (set by the Justfile) — fallback is a scan of virtiofs/9p/fakeowner mounts for a `.rp/` marker. It then captures an fd on that bind, stacks a tmpfs (fail-closed backstop) and `rp-fuse` on top; the user/Claude sees the FUSE layer. The raw bind is reachable only via `rp-fuse`'s captured fd (`/proc/self/fd/N`). See `CONTEXT.md` for vocabulary, `docs/adr/0001-custom-go-fuse-for-workspace-shadowing.md` for the design rationale, and `docs/adr/0010-setuid-init-bootstrap.md` for the mount layout.
- Container name and bind-mount source both come from `invocation_directory()` (a `just` builtin returning caller's cwd before `just` chdirs to the justfile dir). The Justfile resolves the agent at every invocation via `rp-fuse config field agent` against the workspace's `.rp/config.yaml`.
- Each container records its mount path as a label (`rp.host_path=<absolute path>`). Interactive recipes verify this label matches the current cwd to prevent collisions — if `rp-claude-code-foo` exists but was created from `~/work/foo`, running `rp run` from `~/personal/foo` aborts with a clear error.
- The `_ensure` helper recipe is called as a dependency by `shell`/`login`/`run`: it auto-creates the container if missing, runs the collision check, and starts it if stopped.
- Auth is per-agent: the profile's `manifest.env` declares which host env vars to forward (e.g. `ANTHROPIC_API_KEY` for claude-code); the profile's `login.sh` runs the subscription / interactive auth flow if it exists.
- `rp create [--name N] [PATH[:ro]...] [-- <container-args>]` aligns with `sbx run`: positional paths become workspaces (1:1 bound, FUSE-shadowed), `:ro` marks a workspace read-only, `--name` overrides the default (repo-scoped slug of the first PATH). Extras after `--` flow through to `container create`. Same shape for `rp run`; extras after `--` go to the agent's run script.
- **Git worktrees** (ADR-0019): the `rp` wrapper detects when the primary workspace is a *linked* worktree (`git rev-parse --git-dir` != `--git-common-dir`) and auto-appends the common git dir (e.g. a sibling `.bare/`) as a 1:1 bind, so the worktree's absolute `gitdir:` indirection resolves inside the container. The common dir has no `.rp/`, so `rp-init.sh` leaves it as a raw passthrough (one benign "no .rp/, skipping" log line). Opt out with `RP_NO_WORKTREE_BIND=1`. Running from the repo top level needs no auto-bind (the single 1:1 bind already covers it).
- `rp` defaults to `~/repos/robo-pen`; override with `ROBO_PEN_DIR`.
- `build-base` builds the foundational `rp-system` image; `build` builds the default `rp-default` image (standalone, not FROM rp-system — the overlay injects rp-system's runtime bits at create time for any project image, same mechanism regardless of source). Both use `{{justfile_directory()}}` as the build context so they work regardless of where `rp` was invoked. `rebuild` no-caches both layers.
- **Per-project images** (ADR-0006 + ADR-0007): every workspace goes through the overlay. `scripts/build-project-image.sh` reads `.rp/config.yaml` for `image:` / `build:` (defaults to `rp-default`) and the agent profile (defaults to `claude-code`), then composes a final image tagged `<container-name>:latest-rp`. The overlay installs fuse3, validates/creates the configured user, mkdir's `/var/lib/rp` at 0700, COPYs `rp-fuse` + `rp-init.sh` from the locally-tagged `rp-system`, COPYs the agent profile's install.sh / settings / instructions / run scripts, runs install.sh as the configured user, and concatenates `/etc/rp/instructions/*.md` into the agent's `instructions_dst`.
- **Agent profile lookup** (ADR-0007): workspace `.rp/agents/<name>/manifest.yaml` overrides repo `agent.profiles/<name>/manifest.yaml`. A directory without `manifest.yaml` is treated as not-present; `rp lint` warns on partial workspace overrides.
- **Edit-config cycle**: changes to `.rp/config.yaml` (agent, image, user, resources, fuse.cache) take effect only at container CREATE time. To pick them up, `rp destroy && rp run` (or `create`). `.rp/shadow` is re-read on every `rp start`, so for shadow-rule-only changes a `rp stop && rp start` suffices.
- **Debug toggle**: `RP_DEBUG=1 rp create <name>` forwards the env var into the container; `rp-init.sh` then launches `rp-fuse --debug` for verbose FUSE logging. `RP_DEBUG=1 rp build` (via `rp create`) also prints the generated overlay Dockerfile.
- **Runtime knobs** (ADR-0006 v1 Tier-1): `.rp/config.yaml` supports `resources.memory` (string like `4G`), `resources.cpus` (positive int), and `fuse.cache` (seconds float). Read by `scripts/resolve-create-args.sh` at create time; memory/cpus become `container create --memory`/`--cpus` flags, fuse.cache is forwarded as `-e RP_CACHE=…` and picked up by `rp-init.sh`. `rp lint` validates all of them.
- **Shadow filtering via `.rp/shadow`** (`rp-fuse` driven, launched by `rp-init.sh` at PID 1): containers are created with `--cap-add SYS_ADMIN`; the unified ENTRYPOINT (`rp-init-bootstrap`, setuid 4755) ensures PID 1 reaches root regardless of the image USER or the runtime's default user (see ADR-0010). The init script discovers the workspace path, then captures an fd on the bind, stacks tmpfs over the workspace path, and execs `rp-fuse --backing-fd N --shadow /var/lib/rp/shadow --mount <ws> --rules /proc/self/fd/N/.rp/shadow`. `.rp/shadow` uses a strict subset of gitignore syntax (one pattern per line; `*`, `**`, `?`, `[…]`, leading `/` or any mid-`/` anchors to root, trailing `/` for directory-only; no negation). For every path that matches a pattern:
  - Host's matching content is INVISIBLE in the container (`stat` returns ENOENT).
  - Container creates/writes/deletes go to `/var/lib/rp/shadow/<rel-path>` — NEVER to the host bind.
  - Build scripts that `rm -rf node_modules && reinstall` are fully contained: the host filesystem is never touched.
  - The shadow store survives `rp stop`/`start`; wiped on `rp destroy`.
- Paths NOT matched by `.rp/shadow` pass through `rp-fuse` to the host bind (reached via the captured fd). Edits to source files propagate to the host as expected.
- Init runs as root (UID 0) for `/dev/fuse` access; `container exec -u coder` on all interactive recipes (`shell`, `login`, `run`) so user sessions run as `coder`. `rp-fuse` mounts with `allow_other`, and `/etc/fuse.conf` has `user_allow_other` enabled in the image.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for this repo. Skills use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo — one `CONTEXT.md` + `docs/adr/` at repo root (produced lazily by `/grill-with-docs`). See `docs/agents/domain.md`.
