# Path-based workspace identity; container names are labels

Until now a container was found **by name**: `rp-<agent>-<basename of the primary workspace>`. The `rp.host_path` label was only checked afterwards, to abort when the name pointed at a different path. With worktrees named after branches, names collide all the time: every repo has a `main`. A second `rp run` then hits the first repo's container and aborts, and the user has to pass `--name` in every worktree.

The underlying mistake is treating the name as the identity. What a user means by `rp run` is "the container for this directory".

## Decision

1. **The canonical primary workspace path is the identity.** `rp` looks up the container whose `rp.host_path` label equals the canonical (`pwd -P`) path of the primary workspace. Existing containers already carry that label, so they are found without migration (ADR-0025).
2. **The name is a readable label, assigned once at create.**
   - Repo slug: the basename of the git common dir with a trailing `.git` removed. If the dir is literally named `.git` or `.bare`, the basename of its parent is used instead. So `~/proj/.git` and `~/proj/.bare` give `proj`, and `~/repos/proj.git` gives `proj`.
   - Workspace part: the git worktree id (the `<id>` in `<common-dir>/worktrees/<id>`). Git keeps it unique within a repository (`main`, `main1`). It is omitted for a main worktree or plain clone.
   - Name: `<repo>-<worktree-id>`, or `<repo>` for a main worktree. A non-git directory uses its basename. If a container for a **different** path already holds the name, a numeric suffix is appended (`-2`, `-3`).
   - Slugs are sanitised to `[A-Za-z0-9._-]`, with leading and trailing dots and dashes trimmed.
3. **`--name` stays an explicit override**, for creating and addressing a container by name, including several containers on one path.
4. **On-disk keys use path hashes, not names.** Names can carry collision suffixes and can be overridden, so they are not stable keys. State directories are keyed by the identity:
   - repo key: `<repo-slug>-<hash8(canonical common dir)>`
   - workspace key: `<container-name>-<hash8(canonical primary workspace path)>`

   The slug only makes the directory recognisable when browsing. The hash guarantees uniqueness, e.g. for two repos both called `proj`. A repo key exists only for git workspaces. The canonical common dir is the one path all worktrees of a repo share, and it is unique per repo in every layout. The repo home from ADR-0023 is not unique in layout C.
5. **The model applies uniformly** to plain clones, worktrees and non-git directories. A worktree is simply the case where several workspaces share one repo.

## Rejected alternatives

- **Keep name-as-identity with a better naming scheme.** Two repos with the same basename (`~/work/proj` and `~/oss/proj`) still collide and need `--name`. No naming heuristic can be perfect, but identity by path doesn't need one.
- **A hash in the container name** (`proj-main-a1b2c3`). Unique, but unreadable in `rp list`, `container ls` and image tags.
- **An ID stored in the repository** (e.g. in the common dir's `config`). It would survive moves, but it writes into the user's repo, and the agent can write it.

## Consequences

- Moving a repository or worktree on disk (`mv`, `git worktree move`) changes its identity. The old container, workspace volume and repo memory are orphaned, and `rp gc` reports them (ADR-0025).
- Every lookup costs one `container list` with a label filter. The old label check already paid that.
- Docker Sandboxes use the same model: running `sbx run` on the same path reconnects to the existing sandbox, and `--name` creates additional ones.
