# Agent state lifetime: per-workspace volumes, per-repo memory

ADR-0014 keyed volume backing dirs by container name (`$RP_VOLUMES_DIR/<container>/<volume>/`) and kept them across `rp destroy`. Short-lived, parallel worktree containers (ADR-0019) need a different split:

- **Credentials** no longer need a shared volume. `host_keychain` and `host_files` (ADR-0015) seed them at create, and every worktree now gets them from the repo home's `config.local.yaml` (ADR-0023).
- **Session state** (`.claude.json`, history, transcripts) should not be shared between parallel containers. Concurrent writes to `.claude.json` over virtiofs race, and each task's conversation belongs to that task.
- **Claude Code's auto-memory** is deliberately per repository and shared across worktrees. Its `~/.claude/projects/<project>/memory/` key is derived from the git repo, not the worktree path. A per-container volume would lose each task's learnings with the container.

## Decision

1. **Workspace-scoped volumes live as long as the workspace, not the container.** They are keyed by the workspace key (ADR-0021) at `$RP_VOLUMES_DIR/workspaces/<workspace-key>/<volume>/`. `rp recreate` replaces the container and keeps the volume, so login, session history and `--resume` survive an image change. `rp destroy` removes it (ADR-0025). Each volume dir stores the canonical workspace path in a small metadata file, so `rp gc` can detect orphans.
2. **Volumes gain a `scope`** in the profile manifest: `workspace` (the default) or `repo`. Repo-scoped volumes live at `$RP_VOLUMES_DIR/repos/<repo-key>/<volume>/` and are bound into every container whose primary workspace belongs to that repo. Repo-scoped volumes require a git workspace. For a non-git directory they fall back to workspace scope.
3. **The claude-code profile declares a repo-scoped `claude-memory` volume** and points Claude Code at it with `autoMemoryDirectory`. That setting goes into managed settings in the image (`/etc/claude-code/managed-settings.json`), not into `~/.claude/settings.json`, which `host_files` may overwrite with the host's copy. Memory then:
   - survives `destroy`
   - is shared by parallel tasks of the same repo, as Claude Code intends
   - stays separate from the host's own memory

   Managed settings take precedence over every other scope, so a host `settings.json` copied in by `host_files` cannot override it. The minimum Claude Code version that honours `autoMemoryDirectory` is not documented. The image build verifies it empirically.
4. **Secondary workspaces don't get their own memory.** The repo of the primary workspace owns the memory scope.
5. **Shadowed dependencies stay container-local** (`/var/lib/rp/shadow`, ADR-0010). They survive `stop` and `start` but not `recreate`. Unlike session history they can be rebuilt, and `recreate` is rare (ADR-0022). Shared package-manager caches (npm/pnpm store, uv, cargo registry) are the follow-up for faster installs in new worktrees. They probably fit the new volume scopes.

## Rejected alternatives

- **Everything per container** (ADR-0014's key with destroy semantics). Auto-memory dies with each task, and parallel tasks never see each other's memory.
- **Everything per repo** (one `~/.claude` for all worktree containers of a repo). Parallel containers would share `.claude.json`, credentials and history. That is a race risk, and it mixes conversations between tasks.
- **Binding the host's own memory dir** (`~/.claude/projects/<slug>/memory`). Host and container would share one memory, but every agent would get write access to context that the user's **unsandboxed** host sessions load. That makes it a persistence channel for prompt injection, and unlike edits to the repo's `CLAUDE.md` it doesn't show up in `git diff`.
- **Moving the shadow store into the workspace volume** so dependencies survive `recreate`. A host dir over virtiofs is much slower than container-local disk for `node_modules`-sized trees, and it would touch the FUSE storage model (ADR-0008) for a rare event.

## Boundaries

- Each container holds its own copy of the OAuth token. If the provider rotates refresh tokens, a refresh in one container can invalidate the copies in others, which then need `rp login` or a recreate. This is accepted, to be revisited if it shows up in practice.
- Auto-memory written by agents is shared across the repo's containers, so a misbehaving task can affect the memory of later tasks. It never reaches host sessions.
- Docker Sandboxes take the same direction: state is per sandbox by default, and selected parts persist explicitly on the host through kits.

This ADR supersedes ADR-0014's volume key and its "volumes survive `rp destroy`" lifecycle.
