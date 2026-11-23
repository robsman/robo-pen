# Container Environment

You are running inside an isolated container (Debian trixie). You run as user `coder` (uid 1000) with no privilege escalation — there is no `sudo`. System-level changes must be made at image-build time on the host, not from inside the running container.

## Directory Layout

- `/workspace` — **Project files**, mediated by `rp-fuse`. All work should happen here.
  - Paths NOT listed in `/workspace/.rp/shadow` pass through to the host bind — edits propagate to the host filesystem normally.
  - Paths LISTED in `/workspace/.rp/shadow` are container-local: their content lives only inside the container's shadow store and never touches the host. Host's matching files are invisible.
- `/workspace/.rp/` — Read-only inside the container (shadow rules, `config.yaml`, agent profiles). Edit it from the host to change the shadow rules; restart the container (`rp stop && rp start`) for the change to take effect.
- `/home/coder` — Your home directory. Ephemeral — lost when the container is destroyed.

## Git

- In a git worktree, the repository's shared git dir is mounted as well, so `commit`, `branch`, `rebase` and `stash` work normally and show up on the host right away.
- **Do not run `git worktree` commands** (`prune`, `remove`, `move`, `repair`). The repository's other worktrees are not mounted here and look deleted, so git would unregister them on the host.
- Git commands that change files under `.rp/` fail, because `.rp/` is read-only. That includes switching to, rebasing onto or resetting to commits whose `.rp/` differs.

## Installing Extra Packages

```bash
# Python packages (prefer uv, user-level)
uv pip install <package>

# Node packages (user-level; --global is also fine, lands in ~/.npm-global)
npm install <package>

# R packages (per-user library)
R -e 'install.packages("tidyverse", repos="https://cloud.r-project.org")'
```

**System packages (apt) are NOT installable from inside the container** — there is no sudo. If you need a new system package, ask the user to add it to the host-side `Dockerfile` and run `rp rebuild`.

## Tips

- Build artifacts (`node_modules`, `.venv`, `target`, etc.) that should not pollute the host filesystem belong in `.rp/shadow` (already there in the default template).
- `rm -rf node_modules && reinstall` cycles work correctly: the host filesystem is never touched.
- If something goes wrong, the host can destroy and recreate the container without losing host-side `/workspace` files (the shadow store is wiped, the host bind is intact).
