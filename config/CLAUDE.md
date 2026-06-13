# Container Environment

You are running inside an isolated container (Debian bookworm). You run as user `coder` (uid 1000) with no privilege escalation — there is no `sudo`. System-level changes must be made at image-build time on the host, not from inside the running container.

## Directory Layout

- `/workspace` — **Project files**, mediated by `ccr-fuse`. All work should happen here.
  - Paths NOT listed in `/workspace/.ccrshadow` pass through to the host bind — edits propagate to the host filesystem normally.
  - Paths LISTED in `/workspace/.ccrshadow` are container-local: their content lives only inside the container's shadow store and never touches the host. Host's matching files are invisible.
- `/workspace/.ccrshadow` — Read-only inside the container. Edit it from the host to change the shadow rules; restart the container (`ccr stop && ccr start`) for the change to take effect.
- `/home/coder` — Your home directory. Ephemeral — lost when the container is destroyed.

## Available Tools

| Tool | Version/Notes |
|------|---------------|
| git | System package |
| python3 + uv | Use `uv` for Python package/project management |
| Node.js | v22 LTS via NodeSource |
| R | r-base from Debian repos |
| DuckDB | CLI binary |
| just | Command runner |
| build-essential | gcc, g++, make, etc. |
| claude | Claude Code CLI |

## Installing Extra Packages

```bash
# Python packages (prefer uv, user-level)
uv pip install <package>

# Node packages (user-level; --global is also fine, lands in ~/.npm-global)
npm install <package>

# R packages (per-user library)
R -e 'install.packages("tidyverse", repos="https://cloud.r-project.org")'
```

**System packages (apt) are NOT installable from inside the container** — there is no sudo. If you need a new system package, ask the user to add it to the host-side `Dockerfile` and run `ccr rebuild`.

## Tips

- Build artifacts (`node_modules`, `.venv`, `target`, etc.) that should not pollute the host filesystem belong in `.ccrshadow` (already there in the default template).
- `rm -rf node_modules && reinstall` cycles work correctly: the host filesystem is never touched.
- If something goes wrong, the host can destroy and recreate the container without losing host-side `/workspace` files (the shadow store is wiped, the host bind is intact).
- Authentication is handled either via `claude login` (subscription) or the `ANTHROPIC_API_KEY` environment variable (API key).
