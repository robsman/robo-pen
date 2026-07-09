#!/usr/bin/env bash
# build-docker-experimental.sh — produce a linux/arm64 image with the rp
# shadow-FS overlay applied, ready to run under Docker (instead of Apple
# Container). For verifying the FUSE shadow stack on a second container
# runtime, side-by-side with the Apple Container production path.
#
# SCOPE (deliberately narrow — this is a smoke-test tool, not a Docker
# support commitment):
#   * Builds linux/arm64 only, via `docker buildx`. Native on Apple Silicon
#     hosts (no emulation), so build times match the regular `rp build`.
#   * Includes rp-fuse + rp-init.sh + the overlay's fuse3/user/mountpoint
#     setup. Does NOT install any agent profile (no claude/opencode), no
#     /etc/rp/instructions compose, no caller-ownership probe.
#   * Lands the result in the local docker daemon. No push, no registry.
#
# Usage:
#   scripts/build-docker-experimental.sh [--user <name>] [--strip-sudo] [<base-image>]
#
# Flags (mirror .rp/config.yaml semantics):
#   --user <name>    Container user. Defaults to `agent` (matches the
#                    docker/sandbox-templates:* convention). Set to an
#                    image-shipped user (e.g. node) to adopt that user
#                    instead, or to a fresh name to create one in the
#                    overlay.
#   --strip-sudo     Opt in to removing sudo grants for the configured user
#                    during build (ADR-0009). Default off: build fails if
#                    the user has any sudoers entry. The sandbox-templates
#                    shell image grants agent sudo by default, so when
#                    targeting Docker Sandbox you'll typically want this.
#
# Default base: docker/sandbox-templates:shell (the Docker Sandbox shell
# template). Override to target a different base.
#
# Example:
#   scripts/build-docker-experimental.sh                    # sandbox-templates:shell + agent
#   scripts/build-docker-experimental.sh --strip-sudo       # same, with sudo stripped
#   scripts/build-docker-experimental.sh --user node --strip-sudo \
#       mcr.microsoft.com/devcontainers/javascript-node:24
#
# Requires: Docker Desktop with buildx (default on recent installs).
#
# STATUS (2026-06-16): working end-to-end on Docker Desktop for macOS.
# Setuid Go bootstrap (ADR-0010) escalates non-root agent → root,
# setresuid(0,0,0) equalizes RUID so util-linux's mount(8) precheck
# passes, /bin/bash -p preserves EUID through rp-init.sh, CapEff has
# SYS_ADMIN. The bind is mounted directly at /workspace (no separate
# /workspace-real). rp-init.sh captures an fd on the bind, then stacks
# tmpfs + FUSE on top of /workspace; rp-fuse reaches the bind via
# /proc/self/fd/N (magic-symlink resolution bypasses path lookup).
# This sidesteps Docker's fakeowner driver, which refuses any bind/move
# that uses the host-share as source.

set -euo pipefail

RP_USER=agent
STRIP_SUDO=0
DIAGNOSE=0
POC=0
BASE="docker/sandbox-templates:shell-docker"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)
            shift
            [ "$#" -ge 1 ] || { echo "build-docker-experimental: --user needs a value" >&2; exit 2; }
            RP_USER=$1
            shift
            ;;
        --strip-sudo)
            STRIP_SUDO=1
            shift
            ;;
        --diagnose)
            DIAGNOSE=1
            shift
            ;;
        --poc)
            POC=1
            shift
            ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --*)
            echo "build-docker-experimental: unknown flag $1" >&2
            exit 2
            ;;
        *)
            if [ -n "$BASE" ]; then
                echo "build-docker-experimental: unexpected positional arg: $1" >&2
                exit 2
            fi
            BASE=$1
            shift
            ;;
    esac
done

if [ -z "$BASE" ]; then
    echo "build-docker-experimental: BASE empty (shouldn't happen; default is docker/sandbox-templates:shell)" >&2
    exit 2
fi
echo "build-docker-experimental: base=$BASE user=$RP_USER strip_sudo=$STRIP_SUDO diagnose=$DIAGNOSE poc=$POC" >&2

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)

if ! docker buildx version >/dev/null 2>&1; then
    echo "build-docker-experimental: docker buildx not available; install Docker Desktop" >&2
    exit 1
fi

# Derive a filesystem-safe slug from the base image ref. mcr.../universal:linux
# → mcr-universal-linux. Used as a tag suffix so multiple bases coexist.
SLUG=$(echo "$BASE" \
    | tr '/' '-' \
    | tr ':' '-' \
    | tr '.' '-' \
    | sed 's/[^a-zA-Z0-9_-]//g' \
    | sed 's/^mcr-microsoft-com-//' \
    | sed 's/-devcontainers//')

# Append the user to the tag so node/coder variants of the same base
# coexist in the local daemon.
BASE_TAG="rp-system-docker:experiment"
OUT_TAG="rp-docker-experiment:${SLUG}-${RP_USER}"

# --- Stage 1: build rp-system for docker ----------------------------------
echo ">> [1/2] Building $BASE_TAG (linux/arm64) via buildx ..." >&2
docker buildx build \
    --platform linux/arm64 \
    -f "$REPO_DIR/Dockerfile.system" \
    -t "$BASE_TAG" \
    --load \
    "$REPO_DIR"

# --- Stage 2: generate minimal overlay Dockerfile + build it ------------
OVERLAY_CTX=$(mktemp -d -t rp-docker-overlay.XXXXXX)
trap "rm -rf $OVERLAY_CTX" EXIT

{
cat <<EOF
# Auto-generated by build-docker-experimental.sh. Do not edit.
# Mirrors the runtime overlay produced by scripts/build-project-image.sh
# but stripped of agent-profile bits (no install.sh, no instructions, no
# settings files). Used to smoke-test the FUSE shadow stack on docker.
FROM $BASE
USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends fuse3 \\
    && rm -rf /var/lib/apt/lists/*

RUN sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf 2>/dev/null \\
    || echo 'user_allow_other' >> /etc/fuse.conf

# Container user. Either adopt an existing image user or create one fresh.
RUN id -u $RP_USER >/dev/null 2>&1 \\
    || useradd -m -s /bin/bash $RP_USER
RUN test "\$(id -u $RP_USER)" -ne 0 \\
    || (echo "rp-docker-experiment: user '$RP_USER' is root, refusing" >&2; exit 1)
EOF

if [ "$STRIP_SUDO" -eq 1 ]; then
    cat <<EOF
# strip_sudo opt-in (ADR-0009). Removes every common sudo grant for the
# configured user. The post-strip sudoers grep below is the safety net.
RUN rm -f /etc/sudoers.d/${RP_USER} 2>/dev/null || true
RUN sed -i "/^${RP_USER}[[:space:]]/d" /etc/sudoers 2>/dev/null || true
RUN for sd in /etc/sudoers.d/*; do \\
        [ -f "\$sd" ] && sed -i "/^${RP_USER}[[:space:]]/d; /^%sudo[[:space:]]/d; /^%wheel[[:space:]]/d" "\$sd" 2>/dev/null || true; \\
    done; true
RUN gpasswd -d ${RP_USER} sudo 2>/dev/null || true
RUN gpasswd -d ${RP_USER} wheel 2>/dev/null || true
EOF
fi

if [ "$STRIP_SUDO" -eq 1 ]; then
cat <<EOF
# Strip comments before matching so a legitimate base-image comment like
# '# Ditto for GPG agent' in /etc/sudoers doesn't false-positive when the
# user happens to be named the same as a word in those comments.
# Skipped entirely when --strip-sudo was NOT passed: Sandbox-compat builds
# intentionally keep sudo (RP_ALLOW_SUDO=1 lets rp-init.sh launch anyway).
RUN if cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null | sed 's/#.*//' \\
        | grep -qE "(^|[[:space:]])${RP_USER}([[:space:]]|\$)"; then \\
        echo "rp-docker-experiment: user '$RP_USER' has a sudoers entry, refusing" >&2; exit 1; \\
    fi
EOF
fi

cat <<EOF

RUN mkdir -p /var/lib/rp/shadow /workspace /usr/local/lib/rp \\
    && chmod 0700 /var/lib/rp \\
    && chown root:root /var/lib/rp /var/lib/rp/shadow

# Pull rp-fuse + init script + setuid bootstrap + tini from the arm64 rp-system.
# The unified ENTRYPOINT is `tini -- rp-init-bootstrap` (ADR-0010); we COPY
# tini explicitly so the overlay works regardless of whether the user base
# already ships tini.
COPY --from=$BASE_TAG /usr/local/bin/rp-fuse /usr/local/bin/rp-fuse
COPY --from=$BASE_TAG /usr/local/bin/rp-init-bootstrap /usr/local/bin/rp-init-bootstrap
COPY --from=$BASE_TAG /usr/local/bin/rp-init.sh /usr/local/bin/rp-init.sh
COPY --from=$BASE_TAG /usr/bin/tini /usr/local/bin/tini
COPY --from=$BASE_TAG /etc/rp/instructions/00-container.md /etc/rp/instructions/00-container.md
# Re-apply the setuid bit — some Docker variants strip it across COPY --from.
RUN chmod 0755 /usr/local/bin/rp-fuse /usr/local/bin/rp-init.sh /usr/local/bin/tini \\
    && chown root:root /usr/local/bin/rp-init-bootstrap \\
    && chmod 4755 /usr/local/bin/rp-init-bootstrap

WORKDIR /workspace
USER $RP_USER
EOF

if [ "$POC" -eq 0 ]; then
    cat <<'EOF'

# ENTRYPOINT exec-form: when Docker does `docker run <image>`, this runs as
# USER (set above). The setuid bit on rp-init-bootstrap means it transitions
# to root before doing the mount + exec of rp-fuse. See ADR-0010.
ENTRYPOINT ["/usr/local/bin/tini", "--", "/usr/local/bin/rp-init-bootstrap"]
EOF
fi

if [ "$DIAGNOSE" -eq 1 ]; then
    cat <<'EOF'

# Diagnostic mode: rp-init.sh sleeps on any pre-cover failure (instead of
# exiting) and dumps /proc/1/status + env + /proc/mounts + failure reason
# to $RP_LOG_DIR/rp-init.log. Lets you read why init bailed without
# needing to exec into the container — bind /tmp/rp-fuse (host) onto
# /tmp/rp-fuse (container) in your Sandbox template and inspect the log
# on host. NEVER ship a diagnostic image to production — fail-open
# without tmpfs cover is not safe.
RUN mkdir -p /tmp/rp-fuse && chmod 0777 /tmp/rp-fuse
ENV RP_DIAGNOSE=1 RP_LOG_DIR=/tmp/rp-fuse
EOF
fi

if [ "$STRIP_SUDO" -eq 0 ]; then
    cat <<'EOF'

# Sandbox compatibility: the agent user has passwordless sudo (Sandbox
# base-image requirement). rp-init.sh would normally refuse to launch
# when the configured user has any sudoers entry (shadow boundary needs
# no-sudo); RP_ALLOW_SUDO=1 bypasses that check. Inside Sandbox the outer
# VM isolation is the actual security boundary, and the FUSE shadow layer
# becomes a best-effort hint (agent could `sudo umount` it).
ENV RP_ALLOW_SUDO=1
EOF
fi
} > "$OVERLAY_CTX/Dockerfile"

if [ "${RP_DEBUG:-}" = "1" ]; then
    echo ">> generated overlay Dockerfile ↓↓↓" >&2
    sed 's/^/   /' "$OVERLAY_CTX/Dockerfile" >&2
    echo ">> ↑↑↑" >&2
fi

echo ">> [2/2] Building $OUT_TAG (FROM $BASE) via buildx ..." >&2
docker buildx build \
    --platform linux/arm64 \
    -f "$OVERLAY_CTX/Dockerfile" \
    -t "$OUT_TAG" \
    --load \
    "$OVERLAY_CTX"

cat >&2 <<MSG

----------------------------------------------------------------------
Built: $OUT_TAG (linux/arm64), in the local docker daemon.
  base:        $BASE
  user:        $RP_USER$([ "$STRIP_SUDO" -eq 1 ] && echo "  (strip_sudo applied)")

Smoke-test it with:

  mkdir -p /tmp/rp-docker-probe
  docker run --rm -it \\
      --cap-add SYS_ADMIN \\
      --device /dev/fuse \\
      -v /tmp/rp-docker-probe:/workspace \\
      $OUT_TAG

  # No --user flag needed: the image runs as $RP_USER by default, and the
  # ENTRYPOINT is /usr/local/bin/rp-init-bootstrap (setuid root), which
  # bootstraps the FUSE mount as root before exec'ing rp-fuse.

In another shell:
  docker exec -it -u $RP_USER <container-id> bash

Inside, /workspace is the FUSE-mediated mount (FUSE over tmpfs over the
docker bind). /var/lib/rp is the root-only shadow store. .rp/shadow
rules in the workspace are honored. This image does NOT have any agent
installed — it's a FUSE smoke test.
----------------------------------------------------------------------
MSG
