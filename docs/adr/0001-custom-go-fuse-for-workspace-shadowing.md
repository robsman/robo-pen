# Custom Go FUSE for workspace shadowing

`ccr-fuse` is a custom Go FUSE driver built on `hanwen/go-fuse`'s `LoopbackNode`, rather than using kernel `overlayfs`, `fuse-overlayfs`, or per-path bind mounts. Reasons:

- **Bind mounts can't hide a directory entry from `readdir`**, only its content. Required a separate filesystem layer to make shadowed paths truly invisible to the container by default.
- **Bind mounts on the workspace bidirectionally share directory creations** — creating a shadow mount-point on the container side leaks an empty stub directory to the host bind. We need zero host artifacts.
- **`fuse-overlayfs` is a union FS** — every write goes to the upper layer, including writes to non-shadowed paths. That would break the requirement that source edits propagate to host disk.
- **A custom driver lets us route per-path**: passthrough → host bind, shadowed → container-local store. Selective routing is the core capability of the design.

Cost: ~400 LOC of Go + a multi-stage Dockerfile build. Worth it for the semantics we need.
