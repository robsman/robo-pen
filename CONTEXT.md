# claude-container

Tool for running Claude Code inside isolated Apple Container instances. The host directory you invoke `ccr` from is bind-mounted into the container; `ccr-fuse` overlays a rule-aware filesystem on top so selected paths are kept container-local.

## Language

**Shadow**:
A path listed in `.ccrshadow`. The host's content at that path is invisible to the container, and the container's reads/writes go to a parallel container-local store that never touches the host filesystem.
_Avoid_: ignore (misleading — the path is not ignored, just rerouted), mask (misses the writable half), private (the path also exists on host), overlay (collides with kernel `overlayfs`).

**Shadow store**:
The container-local directory backing all shadowed paths, located at `/var/lib/ccr/shadow`. Mirrors the workspace path structure: a shadow for `a/b/c` lives at `/var/lib/ccr/shadow/a/b/c`. Survives `ccr stop`/`start`; wiped on `ccr destroy`.
_Avoid_: overlay store, private store.

**Passthrough**:
A path NOT matched by any `.ccrshadow` rule. Reads and writes go to the host bind mount; edits propagate bidirectionally between host and container.
_Avoid_: passthrough mount (sounds like a filesystem feature), host-backed.

**Workspace**:
The container-visible `/workspace` directory. Composed by `ccr-fuse` from passthrough paths (host-backed) plus shadowed paths (store-backed).

**Workspace-real**:
The raw host bind mount at `/workspace-real`. Implementation detail — the user/Claude should not interact with it directly.

**Shadow rules**:
The pattern set in `.ccrshadow` that determines which paths are shadowed. Syntax is a strict subset of `.gitignore`: same anchoring semantics (leading `/` and mid-slash both anchor to root), `*` / `**` / `?` / `[…]` globs, trailing `/` for directory-only. **Negation (`!pattern`) is NOT supported** and is silently skipped with a warning. The container sees `.ccrshadow` at the workspace root but cannot modify it (writes return EROFS); only the host can edit the rules.
_Avoid_: ignore patterns, ccrignore rules.
