# Repo-scoped container names and per-repo agent volumes

The default container name was `rp-<agent>-<basename of the primary workspace>`.
That is ambiguous the moment the workspace is a git worktree. The bare-repo +
worktree layout (ADR-0019) names worktrees after branches, so every repo on the
machine has a worktree called `main`:

```
~/Projects/proj/main    -> rp-claude-code-main
~/Projects/other/main   -> rp-claude-code-main   # same name, different repo
```

The second `rp run` found the first repo's container, saw a mismatching
`rp.host_path` label, and aborted with a collision error. The user had to pass
`--name` in every worktree, forever.

## Decision

The default container name is repo-scoped: `<repo>-<workspace>`, where `<repo>`
is the directory holding the repository and `<workspace>` is the primary
workspace's directory name. The workspace part is dropped when the two are
equal, so a plain clone keeps the short name it has always had.

```
~/Projects/proj/.bare + ~/Projects/proj/main  -> rp-claude-code-proj-main
~/Projects/proj/feat-x                        -> rp-claude-code-proj-feat-x
~/Projects/other/main                         -> rp-claude-code-other-main
~/Projects/plain        (clone, top level)    -> rp-claude-code-plain
~/notes                 (no git)              -> rp-claude-code-notes
```

1. `scripts/resolve-workspace-name.sh <dir>` is the single source of truth. It
   emits `RP_REPO_SLUG` and `RP_DEFAULT_NAME`. The `rp` wrapper uses it for the
   default `--name`; `scripts/resolve-recipe-ctx.sh` uses it for the fallback
   when a recipe is invoked through `just` directly.
2. The repo is identified by `git rev-parse --git-common-dir`, the one path all
   worktrees of a repo share. The repo root is derived from it: strip a trailing
   `/.git` (plain clone), cut at `/.git/modules/` (submodule — the superproject
   is the repo), otherwise take the parent directory (`<proj>/.bare` → `<proj>`).
   A directory outside any repo falls back to its own basename, unchanged.
3. Both slugs are sanitised to `[A-Za-z0-9._-]` with leading and trailing dots
   and dashes trimmed, so a workspace like `.bare` cannot produce a container
   name starting with a dot.
4. Volume backing dirs move from `$RP_VOLUMES_DIR/<container-name>/<volume>/`
   to `$RP_VOLUMES_DIR/<agent-prefixed repo slug>/<volume>/`. Every worktree of
   one repo therefore shares one `~/.claude`: one `rp login` covers them all.
   The key ignores `--name` on purpose — the agent state belongs to the repo,
   not to the container. `RP_VOLUME_KEY` overrides it.

Each worktree keeps its own container, its own bind, its own `.rp/` and its own
shadow rules. Only the *name* and the *volume key* became repo-aware.

## Consequences

- A workspace that is a worktree gets a new container name. The old container
  is still on disk under the old name; `rp create` / `rp _ensure` print a note
  naming it and the `rp destroy --name <old>` command that removes it.
- A plain clone at its top level keeps its old name and its old volume dir
  (`rp-<agent>-<repo>` is what the container was already called), so nothing
  moves for the common case.
- A worktree's existing volume dir (`rp-<agent>-main/`) is orphaned rather than
  migrated. The first run after the change asks for one `rp login`. Migration
  was rejected: guessing which old dir belongs to which repo is not reliable,
  and the recovery is one command.
- Two repos whose top-level directories share a name (`~/work/proj` and
  `~/personal/proj`) still collide. The `rp.host_path` label check catches it
  with a clear error, exactly as before; `--name` disambiguates.

## Rejected alternatives

- **One container per repo, binding the whole repo tree.** ADR-0019 already
  rejected this for the workspace model: shadow rules become tree-wide, `.rp/`
  moves to the repo top level, and every worktree shares one agent process.
  Repo-scoped naming solves the collision without moving the workspace.
- **Hash the workspace path into the name** (`rp-<agent>-main-a1b2c3`). Unique
  and simple, but unreadable in `rp list`, `container ls` and image tags.
- **Keep basename naming and improve the collision error.** The error was
  already clear. The cost is that every worktree needs `--name` forever, which
  is the actual complaint.

## Validation

`rp-fuse/tests/test-wrapper-naming.sh` (run by `run-host-tests.sh`) builds two
real bare-repo + worktree fixtures plus a plain clone and a non-git directory,
and asserts, via a stubbed `just`, that: worktrees of one repo get distinct
repo-scoped names; the same worktree name in a different repo does not collide;
a plain clone and a non-git directory keep their short names; `--name` still
wins; and named recipes (`shell`, `stop`, …) use the same default.
