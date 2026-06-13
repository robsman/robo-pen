# Shadow as security boundary via drop-sudo + namespace hide

The shadow mechanism is promoted from "ergonomic isolation" to a real security boundary against in-container code. Concretely:

- **`coder` user loses passwordless sudo.** The Dockerfile no longer grants `coder ALL=(ALL) NOPASSWD:ALL`.
- **`ccr-init.sh` hides `/workspace-real` from the container's mount namespace.** Before `ccr-fuse` starts, init binds `/workspace-real` → `/var/lib/ccr/backing` (root-only, mode `0700`) and overlays a tmpfs on `/workspace-real` so default container view shows it empty.
- **`/var/lib/ccr/` is `0700 root:root`.** `coder` cannot traverse it, so symlinks crafted to escape into the backing path get EACCES.

Verified by spike (2026-06-13): a `coder` exec'd process has `CapInh = CapPrm = CapEff = 0`. `umount` on the tmpfs returns EPERM. The backing bind is not visible to the user.

Trade-off accepted:

- **Lose**: `apt-get`, `pip install -g`, system config changes from inside the container. The in-container `CLAUDE.md` advice to "install anything" is removed; new system packages must be baked into the image via `ccr rebuild`.
- **Gain**: Claude (or any in-container process) genuinely cannot read host content outside the `.ccrshadow` ruleset, even with intent.

The earlier broader path to harden was rejected (rewriting go-fuse loopback to `openat`-based access, fork maintenance, fragility). The chosen path is simpler: rely on POSIX perms + capability-less user, plus a tmpfs cover. Container restart is required to take effect; the boundary is enforced from PID 1 onwards.

If Apple Container later exposes per-exec capability controls or per-process mount namespaces, that opens further hardening options without requiring sudo to be dropped.
