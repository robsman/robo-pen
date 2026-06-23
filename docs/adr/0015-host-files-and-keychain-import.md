# Host file + Keychain import at `rp create`

Coding agents accumulate config and credentials on the host that the in-container instance needs to function: settings, the Claude Code OAuth token, git identity, npm registry tokens. Pre-import, every `rp create` produced a container in a blank slate — the agent had to be re-logged-in, gitconfig re-set, npm tokens re-pasted.

ai-pod handles this by copying a fixed set of host files into the container's home volume on first init. Docker Sandbox's blog recipe bind-mounts the entire `~/.claude` (which leaks unrelated session state). claude-code-sandbox specifically extracts the macOS Keychain entry that holds the Claude Code OAuth token. We adopt the file-copy approach + add explicit Keychain support, both declared in the agent profile manifest.

## Schema

`agent.profiles/<name>/manifest.yaml` gains two optional blocks:

```yaml
host_files:
  - src: ~/.claude.json           # ~ expands to host's $HOME
    dst: /home/{{user}}/.claude.json
  - src: ~/.gitconfig
    dst: /home/{{user}}/.gitconfig
    if_missing: skip              # skip (default) | error

host_keychain:                    # macOS-only; skipped silently on Linux/Docker hosts
  - service: Claude Code-credentials
    dst: /home/{{user}}/.claude/.credentials.json
    mode: "0600"                  # default 0600
    if_missing: skip
```

claude-code's built-in manifest ships the minimal sensible set: `~/.claude.json`, `~/.claude/settings.json`, `~/.claude/CLAUDE.md`, `~/.gitconfig`, `~/.npmrc`, plus the `Claude Code-credentials` Keychain entry → `/home/<user>/.claude/.credentials.json`. Other Claude state (session history, indexes, project notes, IDE state) is NOT copied — too project-specific and bulky.

## Storage routing

Two destinations matter:

1. **Inside a persistent volume's mount path** (per ADR-0014). The Justfile + `scripts/seed-host-files.sh` write directly to the host volume backing dir (`$RP_VOLUMES_DIR/<container>/<volume>/<rel>`). The container sees the file through the bind mount; `container start`'s init.sh chowns the volume to `RP_USER`. Survives `rp destroy && rp create` for non-host_files paths (agent writes); re-overwritten by the next `rp create` for host_files paths.

2. **Outside any volume** (e.g. `/home/<user>/.gitconfig` when only `.claude/` is volume-backed). Uses `container cp` after the container starts. Lives in the writable layer. Lost on destroy, re-copied from the unchanged host source on next create.

**Critical:** Apple Container's `container cp` writes into the IMAGE filesystem, NOT through bind mounts. A `container cp settings.json CONT:/home/<user>/.claude/settings.json` while `/home/<user>/.claude/` is a bind mount → file lands in the (shadowed) image layer, invisible to the container. Hence the direct host-side writes for volume-backed dsts.

## Lifecycle

```
rp create
  container create -v <vol-host>:<vol-mount> ...   (per ADR-0014)
  container start                                  (init.sh chowns volumes)
  scripts/seed-host-files.sh:
    for each host_files entry:
      expand ~ → $HOME; check src exists (skip/error per if_missing)
      if dst inside volume mount → write to volume host backing dir
      else → container cp + chown via container exec
    for each host_keychain entry:
      security find-generic-password -s <service> -w → tmp file
      same routing as host_files
```

Subsequent `rp create` (after `rp destroy`) re-runs the seed. Files that the agent wrote inside the container into volume paths NOT touched by host_files survive (the volume backing dir wasn't touched). Files that ARE in host_files get overwritten with the latest host content — desired, since the host is the canonical source.

## Decisions (locked Q1-Q5)

**Q1 — scope** (minimal sensible set): `.claude.json`, `.claude/settings.json`, `.claude/CLAUDE.md`, `.gitconfig`, `.npmrc`, Keychain `Claude Code-credentials`. Skills, hooks, plugins, sessions, projects, cache are NOT auto-copied. Users add via workspace profile override.

**Q2 — Keychain schema**: separate `host_keychain:` field, not a `src: keychain:NAME` prefix inside `host_files`. macOS-only flag is obvious from the field name; lints cleanly.

**Q3 — missing-source behavior**: `if_missing: skip` (default) → INFO log + continue. Per-entry `error` opt-in available.

**Q4 — timing**: once-per-create. Edits to host files don't propagate until `rp destroy && rp create`. Matches the existing edit-config cycle for `.rp/config.yaml`.

**Q5 — write target**: volume mount when possible (so agent writes alongside the seed persist), container layer otherwise.

## Rejected alternatives

- **Mount `~/.claude` from host as a bind volume**. Docker Sandbox's blog recipe; ai-pod's earlier proposals. Leaks the entire host session state (projects, history, IDE indexes) into the container, including content from other unrelated workspaces. Per-file copy is narrower.
- **Re-copy on every start** (not just create). Would catch host-side edits without `rp destroy`. Loses any in-container edits to the same paths. We chose copy-once at create to match the existing edit-config-cycle expectation.
- **Symlink approach** (Docker Sandbox blog: `ln -s /Users/me/.claude ~/.claude`). Pulls in the entire dir, same content-leak issue. Per-file is cleaner.
- **`container cp` for everything** (initial implementation). Apple Container's cp writes into the image layer, NOT through bind mounts — so volume-backed dsts disappeared into a shadowed location and the container saw nothing. Volume-aware routing is required.

## Tests

- `rp-fuse/profile_test.go`: schema parsing, relative-src rejection, relative-dst rejection, `if_missing` enum, mode octal validation, field accessor defaults.
- `tests/integration/test-host-files.sh`: end-to-end. Uses a workspace profile override to point `host_files.src` at test-managed temp paths. Verifies: file copy into volume, file copy into container layer, directory copy, missing-source skip, persistence of volume-backed copies across `rp destroy && rp create`.

13/13 integration + 5/5 host + Go unit tests pass.
