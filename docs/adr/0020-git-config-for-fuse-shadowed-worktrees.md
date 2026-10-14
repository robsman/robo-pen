# git configuration for a bind-mounted, FUSE-shadowed worktree

A workspace is bind-mounted 1:1 and shadowed by `rp-fuse` (ADR-0001, ADR-0010).
The container's `.git` therefore passes through FUSE to the same host directory
the user's own git commands work on. One repository, one index file, two very
different views of it:

| | host | container |
|---|---|---|
| workspace owner | the user (uid 501) | root (uid 0), as `rp-fuse` presents it |
| running as | the user | the configured user, non-root by invariant |
| inode / device | real APFS values | FUSE values |

Git reads all of those. Out of the box that produced three separate failures,
from fatal to merely expensive.

## Decision

The overlay writes three git settings into every composed image
(`scripts/build-project-image.sh`). All three are container-side only; the
host's git configuration is never touched.

### 1. `safe.directory = *` (system config)

`rp-fuse` presents the workspace root as owned by root while the agent runs as
a non-root user. Git's dubious-ownership guard then aborts *every* command. The
container is a single-user sandbox over the user's own bind mounts, so the
ownership guard defends nothing here. `*` is used rather than the workspace
path because the build cannot know the auto-bound worktree common dir
(ADR-0019) ahead of time.

### 2. `core.checkStat = minimal` (system config)

Git's index caches a `stat` per entry to decide what it can skip re-hashing.
Under the default setting it compares inode, device, uid and gid too — the four
fields that cannot match across the bind. Every entry therefore looked dirty,
and git re-hashed the whole worktree through FUSE on every command: **7.1s
instead of 0.4s on a 1841-file repo**.

`minimal` excludes the sub-second timestamps, uid, gid, inode and device. It
still compares whole-second mtime, whole-second ctime (`core.trustCtime`
defaults to true) and file size. To miss a real edit, a file must keep all
three unchanged — the racily-clean window git already lives with everywhere,
and git's own racily-clean re-hash still covers it.

The setting also stops the container from poisoning the index for the host.
With entries reading as clean, the container writes back the host's stat data
untouched; only files it actually modifies get container-side values.

### 3. `GIT_OPTIONAL_LOCKS=0` (image ENV)

The env-var form of `--no-optional-locks`. It stops git taking locks it does
not strictly need — in practice, `git status` refreshing and rewriting the
index.

Two reasons. First, the untracked cache git keeps inside the index cannot work
on FUSE (`untracked cache is disabled on this system or location`), so a
container `git status` would strip the host's cache and make the host rebuild
it on its next command. Second, with `checkStat = minimal` nothing is
stat-dirty, so a refresh buys the container nothing.

`add`, `commit`, `checkout`, `merge`, `rebase` and `stash` take their locks and
write exactly as before. Disabling the optional ones also removes one
host/container race on `index.lock`.

## Rejected alternatives

- **Shadow `.git` so the container gets a private index.** Kills the whole
  point: commits made by the agent would never reach the host repository.
- **`core.trustCtime = false` as well.** Would drop one more comparison, but
  ctime passes through `rp-fuse` consistently today, so it buys nothing and
  weakens change detection. It is the next knob if a future `rp-fuse` change
  makes ctime unstable and the speedup disappears.
- **Have `rp-fuse` report the host's uid/gid/inode instead.** The workspace
  root must read as root for the mount to work, and faking inode numbers would
  break the FUSE identity model (ADR-0008). Configuring git is the smaller fix.
- **Set the config per repository at container start.** Needs `rp-init.sh` to
  write into the user's repo on the host bind. Mutating the user's repo is
  exactly what ADR-0019 refused to do for `git worktree repair`.

## Boundaries

- Each setting is guarded with `command -v git`, so a base image without git
  still builds. The guard runs before the agent profile's `install.sh` — a
  custom base that installs git only in `install.sh` silently misses the
  settings. Acceptable: `robo-pen-default` ships git.
- Files the container really modifies carry container-side stat data in the
  shared index. The host re-hashes those files once on its next command. This
  is unavoidable while both sides share one index, and it is bounded by what
  the agent touched, not by repo size.
- `safe.directory = *` disables the ownership guard for every path in the
  container, not just the workspace. Inside a sandbox whose only mounts are the
  user's own directories, that is the intended scope.
- The host keeps git's default `checkStat`. Users who want the same speedup for
  their own commands can set `core.checkStat = minimal` per repo themselves;
  robo-pen does not write host-side git config.

## Validation

Measured by hand on a 1841-file repo inside a container: `git status` went from
7.1s to 0.4s with `core.checkStat = minimal`. The `safe.directory` change is
covered by every interactive session — without it, no git command runs at all.
No automated test: all three settings need a real container over a real FUSE
mount, which the host test suite deliberately avoids.
