# Cross-region rename keeps EXDEV

A `rename(2)` whose source and destination cross the shadow boundary (shadow → passthrough, or passthrough → shadow) returns `EXDEV`. POSIX-conformant clients (`mv`, `rename(1)`) fall back to copy-then-remove.

We considered returning `EPERM` to block cross-region rename entirely, and partial-allow variants (host→shadow only). We're keeping `EXDEV` despite the silent footgun risk because:

- **`mv` Just Works** for legitimate use cases (reorganising source files within passthrough paths, renaming entries within a shadowed directory).
- **The "leak" is bounded**: only container-generated shadow content can escape, not host-side secrets the container never had access to (the host's actual `.env.local` content is unreachable to the container even via this path).
- **Atomicity is already lost** in any cross-region scenario regardless of error code; explicit `cp + rm` is the deliberate path for the rare case where you really mean it.

The risk surface is:

- `mv shadowed/node_modules other-dir` — moves container-local binaries to host disk (architecture-mismatched).
- `mv shadowed/.env.local backup-name` — writes container's own `.env.local` content to host disk.

The fix for those is documentation, not a blocker. The lint output and `.ccrshadow.example` will mention this explicitly.
