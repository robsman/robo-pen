# robo-pen — Run coding agents safely in Apple Containers

A macOS tool for running coding agents (Claude Code, OpenCode, …) in isolated Apple Container instances. Each container is anchored to a folder on your Mac. A custom FUSE driver (`rp-fuse`) lets you selectively shadow paths so build artifacts and secrets never touch the host filesystem.

Requires Apple Silicon + macOS 26+.

---

## What you get

- **Coding agent in a sandbox.** The container is started with `--dangerously-skip-permissions` but can only touch what you let it touch.
- **Per-folder containers, per-agent.** `cd ~/my-project && rp run` auto-creates `rp-<agent>-my-project` and bind-mounts that folder 1:1 (the path inside the container matches the host path — `~/my-project` shows up at `/Users/me/my-project` both inside and out). Stop, start, destroy — your files stay on the Mac. Same workspace can host parallel containers per agent (Claude Code vs OpenCode side by side).
- **`.rp/shadow` filtering.** A gitignore-style file at your workspace root tells `rp-fuse` which paths are container-local. Host secrets (`.env.local`, `.aws/credentials`) stay invisible. Build artifacts (`node_modules`, `.venv`, `target`) live only in the container, so architecture mismatches and `rm -rf node_modules` cycles never pollute the host.
- **Per-agent profiles.** A profile bundle (`agent.profiles/<name>/` or workspace-local `.rp/agents/<name>/`) defines how to install + run an agent. Switch agents by changing one line in `.rp/config.yaml`.
- **Real security boundary.** The container's user has no `sudo` and no capabilities. The host bind is hidden in a root-only mount; `coder` cannot bypass the shadow layer even with intent. See `docs/adr/0005-shadow-as-security-boundary-via-drop-sudo.md`.

---

## Prerequisites

- Apple Silicon Mac (M1 or newer), macOS 26+
- [Homebrew](https://brew.sh)
- An account with the agent vendor (Claude Pro/Max subscription for claude-code, etc.) or the matching API key

---

## Install

### Via Homebrew (recommended)

```bash
brew install robsman/tap/robo-pen
rp setup
```

`rp setup` installs Apple Container + `jq` + `just`, starts the container service, brings up the builder VM, and pulls the pre-built `rp-base` + `robo-pen-default` images from GHCR (~1.5 GB, one-time). Subsequent invocations are instant.

### Build images locally instead of pulling

If you're developing on the Dockerfiles or want fully reproducible images:

```bash
RP_BUILD_FROM_SOURCE=1 rp setup       # ~15 min on a current Mac
```

### From source (for rp development)

```bash
git clone https://github.com/robsman/robo-pen.git ~/repos/robo-pen
cd ~/repos/robo-pen
./rp setup            # same as above; pulls pre-built images by default
ln -s "$(pwd)/rp" ~/.local/bin/rp     # put rp on PATH
```

The builder VM is a long-lived Apple Container that runs all `container build` invocations. `rp setup` brings it up at the size given by `builder_memory` in the Justfile (default 8G). To change the size later, edit the Justfile and run `rp builder-reset` — `container build -m` does NOT renegotiate a running builder.

---

## Daily use

```bash
cd ~/my-existing-repo
rp run                    # auto-creates the container, opens the agent (bypass-permissions)
rp run --gated            # opens the agent in permission-gated (prompt-on-tool-use) mode
rp shell                  # bash shell into the cwd-anchored container
rp login                  # run the agent's login flow (e.g. Claude subscription auth)
rp stop                   # pause
rp start                  # resume
rp destroy                # remove container (host files untouched)
rp list                   # show all rp-* containers + their workspace paths
rp lint                   # check .rp/{shadow,config.yaml,agents/} in cwd
```

Pass an explicit name as the last argument if you want a different name from the folder basename:

```bash
rp create --name my-name                       # explicit container name
rp create . /Users/me/docs:ro                  # multi-workspace + read-only
rp run --name my-name -- "summarize the README"
```

---

## `.rp/shadow` — selective shadowing

Put a `.rp/shadow` file at the root of any workspace to filter paths between host and container. Syntax is a strict subset of `.gitignore`:

```
# secrets — host versions stay invisible inside the container
.env.local
.aws/credentials
.ssh/id_rsa

# build artifacts — container-local, never pollute the host
node_modules
.venv
target
*.log

# anchored examples
/secret              # only matches /secret at workspace root
build/               # matches dir named "build" at any depth
**/cache             # matches "cache" at any depth (explicit deep-match)
```

Rules:

- `*`, `**`, `?`, `[abc]` globs
- Leading `/` or any mid-pattern `/` anchors to workspace root
- Trailing `/` restricts to directories
- No negation (`!pattern`) — skipped with a warning
- `#` comments only at the start of a line

For every matched path:

- Host's file/dir is invisible (`stat` returns ENOENT until the container writes there).
- Container creates/writes/deletes go to `/var/lib/rp/shadow/<rel-path>`, never to the host bind.
- `rm -rf node_modules && npm install` cycles work normally — host stays untouched.
- The shadow store survives `rp stop`/`start`. `rp destroy` wipes it.

Edit `.rp/shadow` from the host. Inside the container it is **read-only** — the agent can `cat` it to understand what's filtered but cannot modify the ruleset. Changes require `rp stop && rp start` to take effect.

See `.rp.example/shadow` for a copy-paste-ready starting point.

### `rp lint`

Sanity-check your workspace setup:

```bash
$ cd ~/my-project
$ rp lint
.rp/shadow:1: node_modules     OK    literal-unanchored
.rp/shadow:2: *.log            OK    glob-unanchored

Summary: 2 active, 0 warning, 0 error

.rp/config.yaml: OK
  agent: claude-code (default)
  image source: default (robo-pen-default)
  container user: coder (default)

agent profile claude-code: OK (builtin)
  ...
```

Exit code 1 if any error-status lines — usable as a pre-commit hook or CI check.

---

## Agent profiles

Each container runs one **agent**. Agents are profile bundles that define how to install + run + log in + permission-gate a particular coding TUI.

- **Built-in profile:** `agent.profiles/claude-code/` (Anthropic Claude Code, v1's only shipped profile).
- **Workspace override:** drop `manifest.yaml` + scripts at `<workspace>/.rp/agents/<name>/` to override the built-in or define a new agent without patching robo-pen. See `examples/opencode/` for a worked example.
- **Profile contents:** `manifest.yaml` (env vars, file COPYs, instructions destination, optional entrypoint overrides), `install.sh` (runs as the container user at overlay-build time), `run.sh` (bypass-permissions exec), `run-gated.sh` (optional permission-gated exec), `login.sh` (optional auth flow), `settings/` (files baked into the image), `instructions.md` (agent-specific fragment for the composed CLAUDE.md / AGENTS.md).

The container's instruction file (e.g. `~/.claude/CLAUDE.md` for claude-code) is composed at build time from:

1. `00-container.md` (agent-agnostic container fundamentals from `rp-base`)
2. `10-toolchain.md` (toolchain table from the project image)
3. `20-agent.md` (the profile's `instructions.md`)
4. `30-workspace.md` (optional `.rp/instructions.md` in the workspace)

Concatenated lexically into the path declared by the profile's `instructions_dst`.

To switch agents, set `agent: <name>` in `.rp/config.yaml` and `rp destroy && rp run`.

---

## Per-project images

The default workspace image is `robo-pen-default` (Node 22 + Python+uv + R + DuckDB + just + build-essential). If you want a different base — a Python-only image, a different Node version, your own pre-built tooling — drop a `.rp/config.yaml` in your workspace.

### Pull a pre-built image
```yaml
# .rp/config.yaml
image: python:3.12-slim-bookworm
```
On first `rp run` rp composes the overlay onto the image (fuse3, rp-fuse, mount points, user, agent profile install) and tags the result `<container-name>:latest-rp`. Subsequent starts reuse the composed image.

### Build locally from your own Dockerfile
```yaml
# .rp/config.yaml
build:
  context: .                # relative to .rp/
  dockerfile: Dockerfile
  args:
    NODE_VERSION: "22"
```
…or, equivalent shorthand without a config file: just drop a `.rp/Dockerfile`. rp will build it and apply the overlay.

### Pick the container user
Default is `coder` (uid auto-assigned by useradd). Override via `user:` to either adopt an existing user from the base image or create a different name:

```yaml
# Adopt the existing `node` user shipped by node:22-bookworm.
image: node:22-bookworm
user: node
```

```yaml
# Devcontainer images often ship a privileged `node` user (with sudo).
# Setting user: coder makes the overlay create a fresh non-privileged
# coder user — the rp security boundary needs uid != 0 + no sudoers.
image: mcr.microsoft.com/devcontainers/javascript-node:22
user: coder
```

The overlay tries `useradd` and falls through to the existing user if `id -u <name>` already succeeds. Either way, the build fails if the chosen user has uid 0 or any sudoers entry.

### Quick start from the template
```bash
cd ~/my-project
rp init                       # copies .rp.example/ → .rp/ (refuses if .rp/ exists)
$EDITOR .rp/shadow .rp/config.yaml
rp run                        # first run builds the project image
```
`rp init --force` overwrites an existing `.rp/`.

### Constraints
- **Debian/Ubuntu bases only** (v1). The rp overlay installs `fuse3` via `apt-get`, so Alpine, RHEL, Arch, distroless, etc. bases are rejected up front with a clear error pointing at ADR-0006. Good bases: `debian:bookworm-slim`, `ubuntu:24.04`, `node:*-bookworm`, `python:*-slim-bookworm`. If you need Alpine-flavored tooling today, write a Debian-based `.rp/Dockerfile` that installs the equivalent packages via apt.
- `.rp/config.yaml` recognised keys: `agent`, `image`, `build` (with `context`, `dockerfile`, `args`), `user`, `resources.memory`, `resources.cpus`, `fuse.cache`. Anything else parse-errors with line numbers.

### Edit-config workflow
Changes to `.rp/config.yaml` or to a profile take effect at container CREATE time. To pick up edits:

```bash
rp destroy && rp run     # rebuilds the project image + reapplies config
```

`rp stop` + `rp start` is enough only for re-reading `.rp/shadow` rules (since rp-fuse re-reads them at every start). Anything that affects image composition (agent, image, build, user, resources) requires `destroy + create`.

### Diagnosing FUSE issues
Set `RP_DEBUG=1` in the host shell when creating the container to enable verbose FUSE logging inside rp-fuse, plus dumping the generated overlay Dockerfile to stderr:

```bash
RP_DEBUG=1 rp create --name myname    # forwarded into the container as -e RP_DEBUG=1
rp logs myname                  # the verbose stream
```

### Diagnosing OOM kills
Apple Container's default per-container memory ceiling is **1G** — enough for an interactive shell, but `npm install` / `cargo build` / large `pip install` on real projects will blow past it and get the process killed without warning.

```bash
rp stats                                    # live RSS / CPU
# Inside the container, after a kill:
container exec -u root rp-<agent>-<name> sh -c '
  cat /sys/fs/cgroup/memory.max
  cat /sys/fs/cgroup/memory.events            # oom_kill > 0 confirms it
'
```

Fix by raising the limit in `.rp/config.yaml`:

```yaml
resources:
  memory: 8G                                  # or 12G/16G — whatever the Mac can spare
  cpus: 4
```

Then `rp destroy && rp create` (memory is a create-time flag).

---

## What happens inside the container

- You run as the configured user (default `coder` uid 1000), **no sudo**. System packages must be added at image-build time (edit `Dockerfile` or your per-project `.rp/Dockerfile`, run `rp rebuild`).
- The workspace (host path, 1:1 inside the container) is a FUSE mount served by `rp-fuse`. Passthrough paths reach the host bind; shadowed paths live in a container-local store.
- Toolchain comes from the project image; the agent comes from the configured profile. With the default image + claude-code profile that's: `git`, `python3 + uv`, `node 22`, `R`, `DuckDB`, `just`, `build-essential`, `claude`.
- Auth: per-agent. claude-code uses `rp login` (Anthropic subscription) or `ANTHROPIC_API_KEY`. Other profiles declare their own env vars in `manifest.env`.

---

## Migrating from claude-container

Hard break — there is no back-compat shim. Steps:

```bash
# 1. Destroy any old claude-* containers
ccr destroy && cd ~/my-project    # or: container delete claude-my-project

# 2. Rename the workspace config dir
mv .ccr .rp

# 3. Set ROBO_PEN_DIR (replaces CLAUDE_CONTAINER_DIR)
export ROBO_PEN_DIR=$HOME/repos/robo-pen

# 4. Use the new wrapper
rp build && rp run
```

The container prefix changed from `claude-<basename>` to `rp-<agent>-<basename>`. The `agent:` field in `.rp/config.yaml` defaults to `claude-code`, so existing workspaces keep working with the same agent.

See ADR-0007 for the full design rationale.

### Upgrading across the FUSE-over-bind layout change (2026-06-16)

The mount layout was simplified: the host workspace is now bind-mounted 1:1 (the path inside the container matches the host path) instead of at a fixed `/workspace`. FUSE + tmpfs still stack on top. **Existing containers built before this change must be recreated** — the bind target moved, so on restart the workspace path would not exist inside the container.

```bash
rp destroy && rp create
```

No workspace data is touched; only the container is rebuilt. See ADR-0010 for the layout.

### Upgrading across the sbx-aligned CLI (2026-06-20)

The container name is no longer a positional arg on `rp create` / `rp run`. Positional args are now workspace paths (default `.`); the container name comes from `--name` (overrides the default basename(first PATH)). Append `:ro` to a path to mount that workspace read-only. Multi-workspace shipped at the same time.

| Before | After |
|---|---|
| `rp create my-name` | `rp create --name my-name` |
| `rp run my-name "prompt"` | `rp run --name my-name -- "prompt"` |
| `rp create my-name -- -v /extra:/extra` | `rp create --name my-name . /extra` (1:1 implicit) — or `--name my-name -- -v /extra:/extra` for raw flags |
| (single workspace at /workspace) | `rp create . /Users/me/docs:ro` (multi-workspace + read-only) |

Existing containers keep working; only the next `rp create` / `rp run` invocation needs the new shape.

---

## Security model

Read `docs/adr/0005-shadow-as-security-boundary-via-drop-sudo.md` for the full reasoning. Short version:

- Default container view shows the workspace mediated by `rp-fuse`. Shadowed paths return ENOENT to the container; only the container's own writes survive there.
- The host bind is mounted 1:1 (same path inside and outside the container); `rp-init.sh` immediately overlays a tmpfs and then `rp-fuse` on top of that workspace path. The raw bind is reachable only via the captured fd held by `rp-fuse` (`/proc/self/fd/N`) — there is no user-visible path to it.
- If `rp-fuse` ever fails to mount or exits, the tmpfs underneath becomes visible — empty, not the raw host bind (fail-closed).
- The shadow store lives at `/var/lib/rp/shadow` (mode 0700, root-only). `coder` cannot traverse it.
- `coder` has no capabilities and no sudo, so it cannot `umount` any of the layers above or escalate to root to bypass them.

What this means concretely: if you list `.env.local` in `.rp/shadow`, the contents of your host `.env.local` are unreachable to anything running inside the container.

---

## Architecture

```
Dockerfile.base          rp-base: debian-slim + fuse3 + rp-fuse + rp-init.sh + coder
Dockerfile               robo-pen-default (FROM rp-base) + Node/Python/R/DuckDB/just (no agent)
Justfile                 rp recipes (build-base / build / build-host / create / start / run / lint / ...)
rp                       thin wrapper; dispatches lint locally, everything else via just
rp-fuse/                 Go source: FUSE driver + lint + config parser + profile resolver + tests
scripts/
  build-project-image.sh project-image overlay builder (called by _ensure / create)
  resolve-create-args.sh translates .rp/config.yaml + profile env into `container create` flags
agent.profiles/<name>/   built-in agent profile bundles (claude-code in v1)
config/
  00-container.md        agent-agnostic container fundamentals (baked into rp-base)
  10-toolchain-default.md image toolchain table (baked into robo-pen-default)
  rp-init.sh             PID 1: sets up the shadow boundary, execs rp-fuse
docs/
  adr/                   architecture decision records (ADR-0001..0007)
  agents/                config for matt-pocock-style engineering skills
CONTEXT.md               domain vocabulary (Shadow, Project image, Agent profile, ...)
.rp.example/             template for .rp/ (shadow + config.yaml)
```

See `CLAUDE.md` for the developer-facing summary and `CONTEXT.md` for the vocabulary used across docs and code.

---

## Tips

- `rp list` shows every container with the host folder it's anchored to. Run this if you forget which container goes with which project.
- If `rp` complains about a collision when you `cd` into a different folder, it means a container with that basename already exists anchored elsewhere. Use an explicit name or destroy the old one.
- For one-off prompts: `rp run "what does this repo do?"` runs the agent with that prompt and exits.
- Updating an API key: edit `.env` in the robo-pen repo or export the var in your shell. Existing containers carry the value baked in at create time — `rp destroy && rp run` to pick up a new value.

---

## Getting help

- Read `CLAUDE.md` for the architecture overview and `docs/adr/` for the decisions behind it.
- `rp lint` to debug rule + profile files.
- File issues on the GitHub repo.
