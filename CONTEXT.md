# robo-pen

Tool for running coding agents (Claude Code, OpenCode, …) inside isolated Apple Container instances. The host directory you invoke `rp` from is bind-mounted into the container; `rp-fuse` overlays a rule-aware filesystem on top so selected paths are kept container-local.

## Language

### Filesystem boundary

**Shadow**:
A path listed in `.rp/shadow`. The host's content at that path is invisible to the container, and the container's reads/writes go to a parallel container-local store that never touches the host filesystem.
_Avoid_: ignore (misleading — the path is not ignored, just rerouted), mask (misses the writable half), private (the path also exists on host), overlay (collides with kernel `overlayfs`).

**Shadow store**:
The container-local directory backing all shadowed paths for one workspace, located at `/var/lib/rp/shadow/<key>` where `<key>` is `sha256(absolute workspace path)[:8]`. Mirrors the workspace's path structure: a shadowed path `a/b/c` inside workspace `W` lives at `/var/lib/rp/shadow/<key(W)>/a/b/c`. Per-workspace keying means a container with N workspaces has N independent stores under `/var/lib/rp/shadow/`. Survives `rp stop`/`start`; wiped on `rp destroy`.
_Avoid_: overlay store, private store.

**Passthrough**:
A path NOT matched by any `.rp/shadow` rule. Reads and writes go to the host bind mount; edits propagate bidirectionally between host and container.
_Avoid_: passthrough mount (sounds like a filesystem feature), host-backed.

**Workspace**:
A host directory exposed inside the container as a FUSE-shadowed view (passthrough paths host-backed + shadowed paths store-backed). Bind-mounted 1:1 — the path inside the container is the same as the path on the host (e.g. `~/work/proj` shows up as `/Users/me/work/proj` in both places). A container may have one or more workspaces; each is independently shadowed. See ADR-0010.
_Avoid_: host workspace, project directory (those name the host-side dir, not the container view).

**Primary workspace**:
The first workspace in a container's workspace list. Drives image-build inputs (`.rp/config.yaml` for agent / user / resources), the default container name (basename), and the `rp.host_path` label used by the collision check on re-attach. Additional workspaces are equal partners at the FUSE level but invisible to image-build resolution.
_Avoid_: main workspace, root workspace.

**Read-only workspace**:
A workspace mounted with `:ro` (e.g. `rp create . /Users/me/docs:ro`). The FUSE layer for that workspace is mounted with the kernel's `ro` flag; writes return EROFS before reaching our handlers. Reads + shadow-rule processing work normally; the shadow store is still allocated but never written to.
_Avoid_: read-only mount (too generic), frozen workspace.

**Shadow rules**:
The pattern set in `.rp/shadow` that determines which paths are shadowed. Syntax follows `.gitignore`: leading `/` and mid-slash anchor to root, `*` / `**` / `?` / `[…]` globs, trailing `/` for directory-only, `!`-prefix for negation (re-expose a path; last-match-wins). The container sees the file but cannot modify it (writes return EROFS); only the host can edit the rules. To re-expose a subtree under a shadowed parent, use per-child patterns (`dir/*` + `dir/**/*` + `!dir/sub` + `!dir/sub/**`) — `dir/**` alone also matches `dir` itself, which would prevent the FUSE Lookup from drilling into the re-exposed subtree.
_Avoid_: ignore patterns, ccrignore rules.

### Image layers

**Base image**:
The shared `rp-base` image, built once per robo-pen release via `rp build-base`. Holds the rp-fuse binary, the rp-init.sh script, the agent-agnostic `00-container.md` fragment, and the bits required by the rp overlay (fuse package, fuse.conf, mount-point directories). Project images derive from it.
_Avoid_: robo-pen image, root image.

**Project image**:
The image actually run by a given container. Composed per workspace from the user's chosen base (either `image:` in `.rp/config.yaml`, `build:` from `.rp/Dockerfile`, or the default `robo-pen-default`) plus the rp overlay layer. Tagged `<container-name>:latest-rp`.
_Avoid_: container image, per-repo image.

**rp overlay**:
The thin layer always applied on top of a user's chosen image. Validates (or creates) the container user, ensures `/etc/fuse.conf` allows non-root mounts, creates `/var/lib/rp` at mode 0700, copies `rp-fuse` + `rp-init.sh` from the base image, and runs the configured agent profile's install + instruction-compose. The layer is what makes any user image runnable as a rp container.
_Avoid_: rp layer, decorator layer.

**Persistent volume**:
A directory inside the container that survives `rp destroy && rp create`. Declared in a profile manifest's `volumes:` block as `{name, mount}`; `mount` is relative to the container user's home. Host backing lives at `$RP_VOLUMES_DIR/<container-name>/<volume-name>/` (default `~/.local/share/robo-pen/volumes`). Used for state the agent writes during a session that should carry over: login tokens, history files, agent-local caches. The first `rp create` seeds an empty volume from `/usr/local/share/rp/seed/<name>/` (the build routes profile `files:` whose `dst` falls inside a volume mount into the seed instead of the mount, so defaults survive being shadowed by the bind). `rp purge` wipes the volume root. See ADR-0014.
_Avoid_: named volume (overloaded by container runtimes), home volume (overspecific).

**Host alias**:
An `/etc/hosts` entry inside the container that resolves a chosen name to either the container's default gateway (the host) or a fixed IPv4. Declared in `.rp/config.yaml` under `host_aliases:`. `host.containers.internal` is always injected automatically (matches ai-pod / Podman / Docker convention). Apple Container has no `--add-host` equivalent, so init.sh appends entries to `/etc/hosts` after the network is up — see ADR-0013.
_Avoid_: host gateway alias (overspecific), host bind (already a workspace term).

**Container user**:
The unprivileged identity the container runs interactive sessions as. Defaults to `coder`, created by the rp overlay with an auto-assigned uid (≠ 0). May be overridden via `.rp/config.yaml`'s `user:` field — either adopting an existing user from the base image or naming a fresh user to be created. rp enforces the invariant that the chosen user has uid ≠ 0 and is not listed in any sudoers file; build fails otherwise.
_Avoid_: workspace user, exec user.

### Agent profiles

**Agent**:
The coding TUI a container runs (e.g. Claude Code, OpenCode). One container runs one agent, selected via `.rp/config.yaml`'s `agent:` field (default: `claude-code`).
_Avoid_: tool, assistant, model, robot.

**Agent profile** (or just **profile**):
A bundle that defines everything needed to make one agent runnable inside the rp overlay: a `manifest.yaml`, an `install.sh`, a `run.sh` (and optional `run-gated.sh`, `login.sh`), `settings/` files, and an `instructions.md` fragment. The overlay COPYs all of these into the project image at build time.
_Avoid_: agent definition, plugin, recipe.

**Built-in profile**:
A profile that ships in this repo under `agent.profiles/<name>/`. v1 ships exactly one: `claude-code`. Adding a new built-in requires a PR.
_Avoid_: bundled profile, vendor profile.

**Workspace profile** (or **workspace override**):
A profile that lives in the workspace at `.rp/agents/<name>/`. Takes precedence over a built-in of the same name when `manifest.yaml` is present. Lets users ship their own agent (or override a built-in for one project) without patching robo-pen.
_Avoid_: user profile, local profile, custom profile.

**Profile manifest**:
The `manifest.yaml` at the root of a profile bundle. Declares the profile's `name`, `description`, `env:` allow-list (host env vars forwarded into the container), `files:` (static files COPYed into the image), `instructions_dst` (path of the composed instruction file), and `entrypoints:` (overrides for the conventional sibling-named scripts).
_Avoid_: profile config, profile spec.

**Composed instructions**:
The file written by the overlay at the profile's `instructions_dst` (e.g. `/home/coder/.claude/CLAUDE.md` for claude-code). Composed at build time by concatenating `/etc/rp/instructions/*.md` in lexical order: `00-container.md` (from rp-base), `10-toolchain.md` (from the project image), `20-agent.md` (the profile's `instructions.md`), and optionally `30-workspace.md` (from a workspace's `.rp/instructions.md`).
_Avoid_: agent prompt, CLAUDE.md (too specific).

### FUSE correctness model

**Shadow phase**:
The high bit (`1<<63`) XOR'd into every shadow-tree node's `StableAttr.Ino` reported to the kernel. Keeps backing-tree and shadow-tree inodes from sharing the same cache identity even when their underlying filesystem inode numbers collide. See ADR-0008.
_Avoid_: shadow bit, namespace bit.

**Caller ownership**:
The contract that files created via the FUSE driver in the shadow store are chowned to the FUSE caller's uid/gid immediately after the underlying syscall, rather than left owned by the FUSE process itself (which runs as root). Required so subsequent caller-owned operations like `fchmod` succeed in the kernel without reaching FUSE. See ADR-0008.
_Avoid_: caller chown (this is the implementation), per-request setuid.
