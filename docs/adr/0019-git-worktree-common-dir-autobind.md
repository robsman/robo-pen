# Git worktree support via common-git-dir auto-bind

robo-pen binds the workspace 1:1 (same absolute path inside and outside the
container) and shadows it with FUSE. That model assumes the git repository is
self-contained under the workspace root — true for a normal clone, where `.git`
is a directory at the workspace root.

Bare-repo + worktree layouts break that assumption. A common convention is:

```
proj/
├── .bare/            # the actual repository (objects, refs, config, worktrees/)
├── .git              # file: "gitdir: ./.bare"
├── main/             # a linked worktree
│   └── .git          # file: "gitdir: /abs/proj/.bare/worktrees/main"
└── release/…/        # another linked worktree
```

A linked worktree's `.git` is a *file* whose `gitdir:` line is an **absolute**
path to `…/.bare/worktrees/<name>`, and that per-worktree git dir's `commondir`
resolves back to `…/.bare`. Both live outside the worktree. When a user runs
`rp run` from inside `main/`, only `main/` is bound — `/abs/proj/.bare` is not
mounted, so every git command inside the container fails ("not a git
repository" / gitdir points to a non-existent location).

## Decision

The `rp` wrapper detects a linked worktree and auto-appends the common git dir
as an additional 1:1 workspace bind.

1. For the primary workspace path, run `git rev-parse --path-format=absolute
   --git-dir` and `--git-common-dir`. A **linked worktree is the only layout
   where these two differ** — for a normal repo (main worktree) both are
   `<workspace>/.git`. This is the discriminator; nothing else fires the path.
2. When they differ and the common dir resolves to a path *outside* the primary
   workspace (and isn't already in the user's path list), append it to the bind
   list. The common dir contains both the shared objects/refs and the
   per-worktree git dir under `worktrees/<name>`, so a single bind covers both
   pieces of the indirection.
3. The bind is read-write (git writes objects, refs, and the worktree index and
   HEAD, all under the common dir) and reuses the existing multi-workspace bind
   plumbing (`-v "$p:$p"`, `RP_WORKSPACE`). No new container/init machinery.
4. Opt out with `RP_NO_WORKTREE_BIND=1`.

Because the auto-bound dir has no `.rp/` marker, `config/rp-init.sh` leaves it
as a raw passthrough bind (it logs one benign "no .rp/, skipping" line and does
not stack tmpfs/FUSE over it). Passthrough is exactly what git wants: direct,
atomic access to the object store on the host.

## Rejected alternatives

- **Bind the top-level dir (the parent holding `.bare/` and all worktrees).**
  Works — everything is 1:1 under one bind — but the agent's workspace becomes
  the whole multi-worktree tree instead of a single worktree, shadow rules must
  be written tree-wide (`**/node_modules/`), and it forces one container across
  all worktrees. Auto-binding keeps the worktree as the workspace. (This layout
  is still supported: run `rp` from the top level and no auto-bind is needed.)
- **`git worktree repair` / rewriting `.git` to a relative gitdir inside the
  container.** Mutates the user's repo and is fragile across the FUSE boundary.
  Auto-bind resolves the absolute path as-is without touching repo files.
- **A new "raw bind" concept distinct from a workspace.** Cleaner conceptually
  (the common dir isn't really a FUSE workspace), but it would need new plumbing
  through the wrapper, Justfile, `container create`, and `rp-init.sh`. Reusing
  the workspace bind list is far less code for the same result; the only cost is
  the cosmetic `rp-init` warning.

## Boundaries

- Detection uses the git-recorded absolute common dir, then canonicalises it
  with `pwd -P` to match how the wrapper binds every other path. Repos reached
  through a **symlinked** path can therefore mismatch the literal `gitdir:`
  string; unsupported for now (no symlinks in the common case).
- The common dir is bound **unshadowed** — the container has full read/write to
  the git store, including `.bare/hooks/`. A hostile agent could plant a git
  hook that later executes on the host. This is inherent to giving the container
  git write access; shadowing/RO-protecting `hooks/` is a possible follow-up
  (would require the top-level-bind or the raw-bind concept above).
- Labels are unaffected: the primary workspace (first path) still drives the
  `rp.host_path` label and agent/user resolution. The container *name* became
  repo-scoped in ADR-0021, because worktrees named after branches made
  basename-only names collide across repos.

## Validation

`rp-fuse/tests/test-wrapper-worktree.sh` (run by `run-host-tests.sh`) builds a
real bare-repo + linked-worktree fixture with `git` and asserts, via a stubbed
`just`, that: a worktree auto-appends the common dir; `RP_NO_WORKTREE_BIND=1`
suppresses it; and a normal repo yields a single bind.
