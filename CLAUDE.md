# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A macOS tool for running Claude Code inside isolated Apple Container containers (Debian bookworm). Requires Apple Silicon and macOS 26+. Containers get full `--dangerously-skip-permissions` access without touching the host. The host directory you invoke `ccr` from is bind-mounted to `/workspace` inside the container.

## Commands

The `ccr` script wraps `just` recipes so you can invoke them from any directory. The current working directory becomes the container's `/workspace` mount; the container name defaults to `basename $PWD`. An explicit `<name>` arg overrides the default.

```bash
# One-time setup (run from anywhere)
ccr setup               # installs Apple Container + jq, starts service
ccr build               # build image from Dockerfile (build context = repo root)
ccr rebuild             # build without cache

# Daily use — cwd-anchored
cd ~/my-existing-repo
ccr claude              # auto-creates container claude-<basename-of-cwd>, mounts cwd
ccr shell               # bash shell inside the cwd container
ccr login               # authenticate Claude subscription
ccr stop                # pause container
ccr start               # resume container
ccr destroy             # remove container (workspace files untouched)

# Explicit name still works (overrides cwd default)
ccr create my-project
ccr claude my-project "prompt"
ccr claude-safe my-project

# Info
ccr list                # all claude-* containers, their status, and workspace path
ccr stats               # CPU/memory usage
ccr logs                # container log output

# File transfer (for paths outside /workspace)
ccr cp-to <name> <src> <dest>
ccr cp-from <name> <src> <dest>
```

## Architecture

```
Dockerfile              — multi-stage: builds ccr-fuse (Go) then composes runtime image (Debian bookworm + Node 22 + Python/uv + R + DuckDB + Claude Code + fuse3)
Justfile                — recipes; containers named claude-<name>; bind mount = invocation_directory()
ccr                     — wrapper that invokes just WITHOUT --working-directory, so just sees the caller's cwd
ccr-fuse/               — Go source for the rule-aware FUSE driver (main.go, host_node.go, rules.go, tests/)
config/
  CLAUDE.md             — baked into image at /home/coder/.claude/CLAUDE.md (Claude's in-container instructions)
  claude-settings.json  — baked into image at /home/coder/.claude/settings.json (bypassPermissions + full allow list)
  ccr-init.sh           — baked into image at /usr/local/bin/ccr-init.sh; runs as PID 1; execs ccr-fuse
.env.example            — template for ANTHROPIC_API_KEY
.ccrshadow.example      — template for .ccrshadow (gitignore-style patterns)
```

**Key design points:**

- Containers are named with prefix `claude-` (e.g., `cd ~/foo && ccr claude` → container `claude-foo`)
- The host dir where `ccr` is invoked is bind-mounted to **`/workspace-real`** in the container. `ccr-fuse` then mounts a rule-aware filesystem at `/workspace`, which is what the user/Claude sees. See `CONTEXT.md` for vocabulary and `docs/adr/0001-custom-go-fuse-for-workspace-shadowing.md` for the design rationale.
- Container name and bind-mount source both come from `invocation_directory()` (a `just` builtin returning caller's cwd before `just` chdirs to the justfile dir)
- Each container records its mount path as a label (`ccr.host_path=<absolute path>`). Interactive recipes verify this label matches the current cwd to prevent collisions — if `claude-foo` exists but was created from `~/work/foo`, running `ccr claude` from `~/personal/foo` aborts with a clear error
- The `_ensure` helper recipe is called as a dependency by `shell`/`login`/`claude`/`claude-safe`: it auto-creates the container if missing, runs the collision check, and starts it if stopped
- `config/CLAUDE.md` and `config/claude-settings.json` are copied into the image at build time — changes require `ccr rebuild` and only affect new containers
- Auth is either `ccr login` (subscription, survives stop/start but not destroy) or `ANTHROPIC_API_KEY` in `.env` (loaded via `set dotenv-load` in Justfile, passed as env var at container creation)
- `ccr create <name> -- <container-args>` passes extra `container` CLI flags (e.g., extra volume mounts, port bindings)
- `ccr` defaults to `~/repos/claude-container`; override with `CLAUDE_CONTAINER_DIR`
- `build`/`rebuild` use `{{justfile_directory()}}` as the build context (not `.`), so they work regardless of where `ccr` was invoked
- **Shadow filtering via `.ccrshadow`** (`ccr-fuse` driven, launched by `ccr-init.sh` at PID 1): containers are created with `--cap-add SYS_ADMIN --user 0`. The init script execs `ccr-fuse --backing /workspace-real --shadow /var/lib/ccr/shadow --mount /workspace --rules /workspace-real/.ccrshadow`. `.ccrshadow` uses a strict subset of gitignore syntax (one pattern per line; `*`, `**`, `?`, `[…]`, leading `/` or any mid-`/` anchors to root, trailing `/` for directory-only; no negation). For every path that matches a pattern:
  - Host's matching content is INVISIBLE in the container (`stat` returns ENOENT).
  - Container creates/writes/deletes go to `/var/lib/ccr/shadow/<rel-path>` — NEVER to the host bind.
  - Build scripts that `rm -rf node_modules && reinstall` are fully contained: the host filesystem is never touched.
  - The shadow store survives `ccr stop`/`start`; wiped on `ccr destroy`.
- Paths NOT matched by `.ccrshadow` pass through `ccr-fuse` to `/workspace-real`. Edits to source files propagate to the host as expected.
- Init runs as root (UID 0) for `/dev/fuse` access; `container exec -u coder` on all interactive recipes (`shell`, `login`, `claude`, `claude-safe`) so user sessions run as `coder`. `ccr-fuse` mounts with `allow_other`, and `/etc/fuse.conf` has `user_allow_other` enabled in the image.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for this repo (`robsman/claude-container`). Skills use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo — one `CONTEXT.md` + `docs/adr/` at repo root (produced lazily by `/grill-with-docs`). See `docs/agents/domain.md`.
