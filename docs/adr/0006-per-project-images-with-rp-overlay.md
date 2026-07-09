# Per-project images with rp overlay

Each rp workspace gets its own image. The image is composed at build time from the user's chosen base (a pre-built reference or a `.rp/Dockerfile`) plus a thin "rp overlay" that adds the bits required for a rp container to actually run.

## Why per-project

A single global image cannot satisfy every project: one wants R + DuckDB, another wants Rust + sqlite, another wants minimal Alpine. Editing the shared Dockerfile to accommodate everyone bloats the image and creates merge pressure. Per-project means each workspace owns its toolchain.

## Why an overlay, not a base-Dockerfile inherit pattern

A user-specified `image: node:22-trixie` is a raw upstream image — it has no `coder` user, no `rp-fuse`, no `rp-init.sh`, no `/etc/fuse.conf` allow_other. Running it directly fails because PID 1 = `/usr/local/bin/rp-init.sh` does not exist. Two choices:

1. Force users to write `FROM rp-default:latest` in every `.rp/Dockerfile`. Tedious, easy to forget, breaks the `image:` case entirely.
2. Always wrap user's image with a rp overlay layer that adds the required bits.

We chose (2). The overlay is a small templated Dockerfile applied at build time; the output is tagged `<source>:<source-tag>-rp`. Users define their image freely; rp guarantees rp-runnability.

## Config

`.rp/config.yaml` uses a subset of `docker-compose` service-level field names (no `services:` wrapper, single service). v1 supports `image`, `build` (with `context`, `dockerfile`, `args`), and `user`. Unsupported keys produce explicit "not yet supported" errors rather than silent ignores. We picked compose-style field names because the OCI ecosystem (Docker, Podman, nerdctl) treats this as the de facto standard; Apple Container provides no native equivalent.

## Container-user flexibility

Some base images establish their own conventional user (`node:22` → `node`, etc.). `.rp/config.yaml`'s `user:` field selects the identity sessions run as. The overlay tries `useradd -m -s /bin/bash <name>` and falls through to the existing user if `id -u <name>` already succeeds — so either an image-defined user can be adopted, or a fresh user created when the image's existing user is unsuitable (e.g. devcontainer images ship a `node` user with sudo, which violates the shadow-boundary invariant in ADR-0005).

After ensure-exists, the overlay still validates that the chosen user has uid ≠ 0 and is not listed in any sudoers file; if either check fails, the build fails loudly. Runtime re-validates. The unprivileged-user invariant is preserved regardless of which image the user picks. We deliberately do not pin uid 1000 — devcontainer images already use 1000 for their default user, so `useradd` is left to pick a free uid.

## Build pipeline

1. `rp build-base` (or `rp setup`'s pull-images path) provides the local `rp-system` image — the overlay's `COPY --from` source for `rp-fuse`, `rp-init.sh`, `rp-init-bootstrap`, `tini`, and `00-container.md`. `rp-system` is never itself the base a project image is `FROM`'d from, including `rp-default` — it's purely an artifact donor the overlay pulls from, for every source kind below.
2. `rp create`/`rp run` (via the `_ensure` recipe) invoke `scripts/build-project-image.sh`, which reads `.rp/config.yaml` and `.rp/Dockerfile` to resolve the source:
   - `image:` set → overlay build on top of that image
   - `build:` set or `.rp/Dockerfile` present → builds the user's Dockerfile first, then the overlay
   - otherwise → overlay build on top of `rp-default` (built via `rp build`)
   - Every case runs the same overlay template — there is no path where a container runs off `rp-system` (or any pre-overlay image) directly.
3. Containers reference the resulting `<container-name>:latest-rp` image.

## Hard switch on migration

No backwards compatibility with the pre-overlay design. Existing in-development containers must be `rp destroy`'d; `.ccrshadow` files moved to `.rp/shadow`; no users are on the legacy layout in production. We pay the rename cost once, up front.

## Debian/Ubuntu-only bases (v1 constraint)

The rp overlay installs `fuse3` via `apt-get`. Alpine, RHEL, Arch, distroless, and other non-Debian bases will fail the overlay build. To surface this as a friendly error rather than a cryptic `apt-get: not found`, `scripts/build-project-image.sh` probes the source image with `[ -f /etc/debian_version ]` before composing the overlay; non-matching images are rejected with a message pointing at this ADR.

Widening to Alpine (apk) and RHEL-like (dnf/yum) bases is straightforward — detect the package manager and branch in the overlay template — but adds an extra dimension of bases to test against. Deferred until there is concrete demand.

If you need an Alpine-flavored toolchain today, write a Debian-based `.rp/Dockerfile` that installs the equivalent tools via apt.
