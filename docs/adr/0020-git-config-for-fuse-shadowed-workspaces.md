# git configuration for FUSE-shadowed workspaces

A workspace is bind-mounted 1:1 and shadowed by `rp-fuse`. The container's git therefore works on the same repository, and the same index, as the user's git on the host. The two sides see that repository very differently:

| | host | container |
|---|---|---|
| workspace root owner | the user (uid 501) | root (uid 0), as `rp-fuse` presents it |
| git runs as | the user | the configured non-root user |
| inode / device | real APFS values | FUSE values |

Out of the box this breaks git in three ways, ranging from fatal to merely expensive. The fixes apply to every workspace, plain clones as well as worktrees (ADR-0019).

## Decision

The overlay writes these settings into every composed image (`scripts/build-project-image.sh`). All of them are container-side only. robo-pen never writes host-side git config.

1. **`safe.directory = *`** (system config). The agent user does not own the root-owned workspace root, so git's dubious-ownership guard aborts every command. The container is a single-user sandbox over the user's own binds, so the guard protects nothing there. `*` is used instead of listing paths, because the build doesn't know the bound common dirs (ADR-0019) ahead of time.
2. **`core.checkStat = minimal`** (system config). By default git compares inode, device, uid and gid in the index stat cache, and those four values can never match across the bind. Every entry therefore looks dirty, and git re-hashes the whole worktree through FUSE. On a 1841-file repo `git status` took 7.1s instead of 0.4s. `minimal` still compares whole-second mtime, ctime and size. It also stops the container from rewriting the host's stat data for files it didn't touch.
3. **`GIT_OPTIONAL_LOCKS=0`** (image ENV). This stops `git status` from refreshing and rewriting the shared index. On FUSE, git's untracked cache is disabled, so a container refresh would strip the host's cache. With setting 2 nothing is stat-dirty anyway. Commands that must write (`add`, `commit`, `checkout`, `rebase`, `stash`) still take their locks.
4. **`gc.worktreePruneExpire = never`** (system config). See ADR-0019: other worktrees are not mounted in a container and must not be pruned from it.

The settings are written straight to `/etc/gitconfig`, not through `git config`. That way they also apply when git is only installed later, by the agent profile's `install.sh`.

## Rejected alternatives

- **Shadow `.git` to give the container a private index.** Commits made by the agent would never reach the host.
- **`core.trustCtime = false`.** ctime passes through `rp-fuse` consistently today, so it adds nothing and weakens change detection. It is the next knob if that ever changes.
- **Make `rp-fuse` report the host's uid, gid and inodes.** The root must read as root for the mount model, and faking inode numbers would break the FUSE identity model (ADR-0008).
- **Write the config into the user's repository at container start.** robo-pen does not mutate user repositories.

## Boundaries

- Files the container modifies carry container-side stat data in the shared index, so the host re-hashes those files once. The cost is bounded by what the agent touched, not by repo size.
- `safe.directory = *` turns off the ownership guard for every path in the container. In a sandbox whose only mounts are the user's own directories, that is the intended scope.

## Validation

Measured by hand on a 1841-file repo: `git status` went from 7.1s to 0.4s. There is no automated test, because all four settings need a real container over a real FUSE mount, which the host test suite deliberately avoids.
