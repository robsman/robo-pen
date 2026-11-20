# Git worktree support: bind the common git dir

The target workflow is short-lived worktrees, one per task, with several agents running in parallel against one repository. Each worktree gets its own robo-pen container (ADR-0021), started quickly from a shared image (ADR-0022).

robo-pen binds each workspace 1:1 and shadows it with FUSE (ADR-0001, ADR-0010). That works for a plain clone, where `.git/` is a directory under the workspace root. A linked worktree breaks it. Its `.git` is a file whose `gitdir:` line points at `<common-dir>/worktrees/<id>`, and that per-worktree dir points back at the common dir through `commondir`. Both live outside the worktree, so with only the worktree bound, every git command in the container fails with "not a git repository".

Three layouts occur in practice:

| Layout | Common dir | Example |
|---|---|---|
| A: in-tree bare repo | `~/proj/.bare` | worktrees `~/proj/main`, `~/proj/feat-x` |
| B: worktrees added from a plain clone | `~/proj/.git` | worktree `~/proj-feat` |
| C: central bare repo | `~/repos/proj.git` | worktree `~/src/proj-main` |

## Decision

1. **Detection.** For each workspace path, the `rp` wrapper runs `git rev-parse --path-format=absolute --git-dir` and `--git-common-dir`. A linked worktree is the only layout where the two differ. Detection runs **per path**, not only for the primary workspace.
2. **Bind the common dir at its 1:1 path.** The common dir holds the shared objects and refs as well as every per-worktree dir under `worktrees/`, so one bind resolves the whole indirection. It works for absolute and relative (`worktree.useRelativePaths`) `gitdir:` entries alike, because the path is the same inside and outside.
3. **One bind per common dir.** Several workspaces of one repo share a single bind. A common dir that already lies inside a bound path (e.g. the user binds `~/proj` in layout A) is not bound again.
4. **Mode follows the workspaces.** The common dir is bound read-write if at least one non-`:ro` workspace uses it, because a writable worktree needs a writable store anyway and git cannot separate the two. If every workspace using it is `:ro`, the common dir is mounted through `rp-fuse` in `:ro` mode with an empty rule set. Read-only git (`log`, `diff`, `status`, `blame`) keeps working, and writes fail with EROFS. `:ro` is enforced only by `rp-fuse` (the runtime's `-v` takes no `:ro`), so a plain passthrough bind would silently break the `:ro` promise.
5. **Read-write git is the default.** Agents commit, branch, rebase and stash on their task branch, and the results appear on the host immediately. This is the same trust level a plain-clone workspace already has, where `.git/` sits read-write inside the bind.
6. **Guard the other worktrees.** Inside a container, every other worktree of the repo looks deleted, because its path is not mounted. `git worktree prune` would remove their admin dirs and break them on the host. The image therefore sets `gc.worktreePruneExpire=never` in the system git config, which stops `git gc --auto` from pruning. The agent instructions for a worktree container also say not to run `git worktree` commands. An explicit `git worktree prune` stays possible; see Boundaries.
7. **Subdirectory workspaces get no git.** If a workspace is a subdirectory of a worktree or clone, the `.git` file above it is not mounted. The wrapper prints a warning naming the worktree root and skips the common-dir bind. Binding just the `.git` file is not an option: git would see every file outside the subdirectory as deleted, and `git commit -a` would commit those deletions.
8. **Opt-out:** `RP_NO_WORKTREE_BIND=1` disables detection.

The bound common dir is not a workspace. It has no `.rp/`, no shadow rules and no tmpfs cover. `rp-init.sh` must treat it as a git-store bind rather than log it as a workspace without `.rp/`. The wrapper passes these paths in a separate list (`RP_GIT_DIRS`, entries `path[:ro]`). Read-write entries stay a plain bind. `:ro` entries go through the same fd capture, tmpfs cover and `rp-fuse` mount as workspaces, but without the `.rp/` requirement. `rp-fuse` already handles this: a missing `.rp/shadow` yields an empty rule set, and `:ro` is part of its workspace spec.

## Rejected alternatives

- **Bind the parent of all worktrees** (`~/proj` in layout A). Git works, but the agent's workspace becomes the whole multi-worktree tree. Shadow rules then have to be tree-wide, and all worktrees share one container, which contradicts one-container-per-task. It also doesn't exist for layout B or C. It is still supported by running `rp` from the parent.
- **Clone mode,** a container-private clone the host fetches from. Docker Sandboxes removed host-side worktree management (`--branch`) in sbx v0.31.0 in favour of this. It removes every shared-store risk below, but gives up robo-pen's core property: the agent's uncommitted edits visible live on the host through the 1:1 bind. Kept as a possible later mode for untrusted agents.
- **No git in worktree containers** (Docker Sandboxes' host-worktree mode). Safe, but agents that cannot commit are much less useful for autonomous tasks.
- **`git worktree repair` or rewriting `gitdir:` inside the container.** Mutates the user's repository across the FUSE boundary.

## Boundaries

- **Host code execution via the git store.** With read-write access, an agent can write `config` (e.g. `core.fsmonitor`, `core.hooksPath`, filter drivers) or `hooks/` in the common dir. Those run on the host the next time the user runs git there. Plain-clone workspaces already have this exposure through `.git/`. Hardening both (read-only `config`/`hooks/` via `rp-init` or `rp-fuse`) is tracked separately. Making only worktrees safer would wrongly suggest plain clones are hardened too.
- **Cross-task damage.** One agent can delete or force-move another task's branch, or run `git worktree prune` explicitly. This is the cost of sharing one repository between parallel tasks. Uncommitted files of a pruned worktree survive on the host, but the worktree must be re-registered.
- **Git operations that rewrite `.rp/` fail in the container.** `rp-fuse` makes the whole `.rp/` tree read-only. Any git command that changes files under `.rp/` in the worktree fails partway with EROFS and can leave the worktree half-updated, to be cleaned up on the host. That covers `checkout`/`switch` to a branch whose `.rp/` differs, `rebase`/`merge`/`cherry-pick` onto commits that touch `.rp/`, `stash pop` and `reset --hard`. This is intended, since the agent must not change rp config, and it applies to plain clones equally. `commit`, `add`, `log`, `diff` and creating branches are unaffected. A `.rp/` change committed through git plumbing without touching the file is still possible. It shows up in review and only takes effect when the host checks it out.
- **Layout C** is fully supported for git and naming. It has no per-repo `config.local.yaml` fallback (ADR-0023).
- **Symlinked paths.** Paths are canonicalised with `pwd -P`. A `gitdir:` written through a symlinked path that differs from the canonical one is not resolved.

## Validation

A host test builds real fixtures for layouts A, B and C with `git` and asserts, via a stubbed `just`, that:

- a worktree gets its common dir appended
- two worktrees of one repo produce one bind
- an all-`:ro` set produces a read-only common dir
- a plain clone and a subdirectory workspace produce no extra bind
- `RP_NO_WORKTREE_BIND=1` suppresses detection
