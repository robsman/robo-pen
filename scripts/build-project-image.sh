#!/usr/bin/env bash
# build-project-image.sh — compose a per-workspace rp image.
#
# Always produces a final image tag (printed on stdout). The image is the
# user's chosen base image plus a rp overlay (ADR-0006) plus the configured
# agent profile bundle's install step and instruction compose (ADR-0007).
#
# Image source (one of):
#   * image: <ref>     -> overlay on top of the upstream image
#   * build: <...>     -> first build user's Dockerfile, then overlay
#   * .rp/Dockerfile  -> shorthand for `build:` with default paths
#   * none of the above -> overlay on top of the global default image
#
# Agent profile:
#   * agent: <name>    -> rp-fuse profile resolve looks up either
#                          .rp/agents/<name>/ (workspace override) or
#                          agent.profiles/<name>/ (builtin)
#   * unset            -> defaults to claude-code
#
# Build-time validation of the chosen user (ADR-0006):
#   - uid != 0
#   - no sudoers entry anywhere
#   - exists in the base image (when `user:` is set explicitly)
#
# Assumes the base image is Debian/Ubuntu-derived (apt-get available).
# Non-Debian bases will fail the fuse3 install step.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: build-project-image.sh <workspace-dir> <container-name>" >&2
    exit 2
fi

WORKSPACE=$1
CONT_NAME=$2

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
RP_FUSE="$REPO_DIR/rp-fuse/rp-fuse-darwin-arm64"
if [ ! -x "$RP_FUSE" ]; then
    echo "build-project-image: host rp-fuse binary missing; run 'rp build-host' first" >&2
    exit 1
fi

CONFIG="$WORKSPACE/.rp/config.yaml"
DEFAULT_DOCKERFILE="$WORKSPACE/.rp/Dockerfile"

# Resolve agent + user from .rp/config.yaml (or defaults).
AGENT=$("$RP_FUSE" config --file "$CONFIG" field agent 2>/dev/null || echo "claude-code")
RP_USER_CFG=$("$RP_FUSE" config --file "$CONFIG" field user 2>/dev/null || echo "")
RP_USER=${RP_USER_CFG:-coder}

# Resolve the agent profile dir (workspace override > builtin).
PROFILE_DIR=$("$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" resolve)
PROFILE_SOURCE=$("$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" source)
echo "build-project-image: agent=$AGENT profile=$PROFILE_DIR ($PROFILE_SOURCE) user=$RP_USER" >&2

# Resolve which image-source kind applies.
SOURCE=$("$RP_FUSE" config --file "$CONFIG" field source 2>/dev/null || echo "default")
if [ "$SOURCE" = "default" ] && [ -f "$DEFAULT_DOCKERFILE" ]; then
    SOURCE="dockerfile_default"
fi

TAG="$CONT_NAME:latest-rp"

# Step 1: produce the SOURCE_REF — the image used as the FROM line in the overlay.
case "$SOURCE" in
    image)
        SOURCE_REF=$("$RP_FUSE" config --file "$CONFIG" field image)
        echo "build-project-image: source=image ref=$SOURCE_REF" >&2
        ;;
    build)
        CTX_REL=$("$RP_FUSE" config --file "$CONFIG" field context)
        DF_REL=$("$RP_FUSE" config --file "$CONFIG" field dockerfile)
        CONTEXT=$(cd "$WORKSPACE/.rp/$CTX_REL" && pwd)
        DOCKERFILE="$CONTEXT/$DF_REL"
        SOURCE_REF="$CONT_NAME:user"
        echo "build-project-image: source=build dockerfile=$DOCKERFILE context=$CONTEXT" >&2
        container build -t "$SOURCE_REF" -f "$DOCKERFILE" "$CONTEXT" >&2
        ;;
    dockerfile_default)
        SOURCE_REF="$CONT_NAME:user"
        echo "build-project-image: source=.rp/Dockerfile" >&2
        container build -t "$SOURCE_REF" -f "$DEFAULT_DOCKERFILE" "$WORKSPACE/.rp" >&2
        ;;
    default)
        SOURCE_REF="robo-pen-default"
        echo "build-project-image: source=default (robo-pen-default)" >&2
        ;;
    *)
        echo "build-project-image: unknown source kind: $SOURCE" >&2
        exit 1
        ;;
esac

# Step 1.5: refuse non-Debian/Ubuntu bases up front. The overlay installs
# fuse3 via apt; Alpine, RHEL, Arch, distroless etc. are not supported in v1.
# Probing with an ephemeral container costs a few seconds but yields a clearer
# error than `apt-get: not found` deep inside the overlay build.
if ! container run --rm "$SOURCE_REF" sh -c '[ -f /etc/debian_version ]' >/dev/null 2>&1; then
    cat >&2 <<MSG
build-project-image: base image '$SOURCE_REF' is not Debian/Ubuntu-derived.

rp's v1 overlay installs fuse3 via apt-get. Alpine, RHEL, Arch, distroless,
etc. bases are not supported yet. Use a Debian-based image
(debian:bookworm-slim, ubuntu:24.04, node:*-bookworm, python:*-slim-bookworm).

See docs/adr/0006-per-project-images-with-rp-overlay.md for the restriction
and the path to widening it.
MSG
    exit 1
fi

# Step 2: assemble the overlay build context.
OVERLAY_CTX=$(mktemp -d)
OVERLAY_DOCKERFILE="$OVERLAY_CTX/Dockerfile"
trap "rm -rf $OVERLAY_CTX" EXIT

# Profile assets that COPY needs to find under the overlay context.
mkdir -p "$OVERLAY_CTX/agent"
cp "$PROFILE_DIR/install.sh" "$OVERLAY_CTX/agent/install.sh"
cp "$PROFILE_DIR/instructions.md" "$OVERLAY_CTX/agent/instructions.md"

# Profile entrypoint scripts — baked into /usr/local/lib/rp/ for `rp run` etc.
for ep_kind in run run_gated login; do
    rel=$("$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" field "entrypoint.$ep_kind")
    if [ -n "$rel" ] && [ -f "$PROFILE_DIR/$rel" ]; then
        # Normalize to a flat filename inside the overlay context (avoids
        # path traversal headaches; the conventional names are unique).
        flat="$(echo "$ep_kind" | tr _ -).sh"
        cp "$PROFILE_DIR/$rel" "$OVERLAY_CTX/agent/$flat"
    fi
done

# Profile files (manifest's `files:` section) — copy each src into the
# overlay context preserving relative path so the COPY line is clean.
FILES_LINES=$("$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" field files || true)
while IFS=$'\t' read -r src dst; do
    [ -z "$src" ] && continue
    mkdir -p "$OVERLAY_CTX/agent/files/$(dirname "$src")"
    cp -R "$PROFILE_DIR/$src" "$OVERLAY_CTX/agent/files/$src"
done <<<"$FILES_LINES"

# Optional workspace-level instruction fragment.
if [ -f "$WORKSPACE/.rp/instructions.md" ]; then
    cp "$WORKSPACE/.rp/instructions.md" "$OVERLAY_CTX/agent/workspace-instructions.md"
fi

INSTRUCTIONS_DST=$("$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" field instructions_dst || true)

USER_EXIST_CHECK=""
if [ -n "$RP_USER_CFG" ]; then
    # User explicitly named in config: must exist in the base image (do not create).
    USER_EXIST_CHECK="RUN id -u $RP_USER >/dev/null 2>&1 \\
    || (echo \"rp-overlay: user '$RP_USER' does not exist in base image\" >&2; exit 1)"
else
    # Default coder: create if missing.
    USER_EXIST_CHECK="RUN id -u $RP_USER >/dev/null 2>&1 \\
    || useradd -m -s /bin/bash -u 1000 $RP_USER"
fi

# Compose the overlay Dockerfile.
{
cat <<EOF
# Auto-generated by rp build-project-image.sh. Do not edit by hand.
FROM $SOURCE_REF
USER root
ENV DEBIAN_FRONTEND=noninteractive

# fuse3 — required for rp-fuse to mount /workspace.
RUN apt-get update && apt-get install -y --no-install-recommends fuse3 \\
    && rm -rf /var/lib/apt/lists/*

# Allow non-root processes to access the FUSE mount.
RUN sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf 2>/dev/null \\
    || echo 'user_allow_other' >> /etc/fuse.conf

# Container user (default coder, or whatever .rp/config.yaml asked for).
$USER_EXIST_CHECK

# Hardening invariants per ADR-0006.
RUN test "\$(id -u $RP_USER)" -ne 0 \\
    || (echo "rp-overlay: user '$RP_USER' is root, refusing" >&2; exit 1)
RUN ! grep -rqE "(^|[[:space:]])${RP_USER}([[:space:]]|\$)" /etc/sudoers /etc/sudoers.d/ 2>/dev/null \\
    || (echo "rp-overlay: user '$RP_USER' has a sudoers entry, refusing" >&2; exit 1)

# Mount points for the shadow boundary + agent entrypoint dir.
RUN mkdir -p /var/lib/rp/shadow /var/lib/rp/backing /workspace /workspace-real /usr/local/lib/rp \\
    && chmod 0700 /var/lib/rp \\
    && chown root:root /var/lib/rp /var/lib/rp/shadow /var/lib/rp/backing

# Pull rp-fuse + init script + container-fundamentals fragment from rp-base.
COPY --from=rp-base /usr/local/bin/rp-fuse /usr/local/bin/rp-fuse
COPY --from=rp-base /usr/local/bin/rp-init.sh /usr/local/bin/rp-init.sh
COPY --from=rp-base /etc/rp/instructions/00-container.md /etc/rp/instructions/00-container.md
RUN chmod 0755 /usr/local/bin/rp-fuse /usr/local/bin/rp-init.sh

# ── Agent profile bundle ($AGENT, source: $PROFILE_SOURCE) ──
COPY agent/instructions.md /etc/rp/instructions/20-agent.md
EOF

if [ -f "$OVERLAY_CTX/agent/workspace-instructions.md" ]; then
    echo "COPY agent/workspace-instructions.md /etc/rp/instructions/30-workspace.md"
fi

for ep_kind in run run_gated login; do
    flat="$(echo "$ep_kind" | tr _ -).sh"
    if [ -f "$OVERLAY_CTX/agent/$flat" ]; then
        printf 'COPY agent/%s /usr/local/lib/rp/%s\n' "$flat" "$flat"
        printf 'RUN chmod 0755 /usr/local/lib/rp/%s\n' "$flat"
    fi
done

# Profile files (manifest's `files:` section).
while IFS=$'\t' read -r src dst; do
    [ -z "$src" ] && continue
    # Template {{user}} in the destination.
    expanded_dst=${dst//\{\{user\}\}/$RP_USER}
    parent_dir=$(dirname "$expanded_dst")
    printf 'RUN mkdir -p %s && chown %s:%s %s\n' "$parent_dir" "$RP_USER" "$RP_USER" "$parent_dir"
    printf 'COPY --chown=%s:%s agent/files/%s %s\n' "$RP_USER" "$RP_USER" "$src" "$expanded_dst"
done <<<"$FILES_LINES"

cat <<EOF

# Run the profile's install.sh as the container user.
USER $RP_USER
COPY --chown=$RP_USER:$RP_USER agent/install.sh /tmp/agent-install.sh
RUN bash /tmp/agent-install.sh && rm /tmp/agent-install.sh

USER root
EOF

if [ -n "$INSTRUCTIONS_DST" ]; then
    expanded_inst=${INSTRUCTIONS_DST//\{\{user\}\}/$RP_USER}
    expanded_dir=$(dirname "$expanded_inst")
    cat <<EOF
# Compose agent instructions from /etc/rp/instructions/*.md (lexical order,
# blank line between fragments) into the agent's expected path.
RUN mkdir -p $expanded_dir \\
    && awk 'FNR==1 && NR>1 {print ""} {print}' /etc/rp/instructions/*.md \\
        > $expanded_inst \\
    && chown -R $RP_USER:$RP_USER $expanded_dir
EOF
fi

cat <<EOF

WORKDIR /workspace
USER $RP_USER
EOF
} > "$OVERLAY_DOCKERFILE"

if [ "${RP_DEBUG:-}" = "1" ]; then
    echo "build-project-image: overlay Dockerfile ↓↓↓" >&2
    sed 's/^/  /' "$OVERLAY_DOCKERFILE" >&2
    echo "build-project-image: ↑↑↑" >&2
fi

echo "build-project-image: building overlay -> $TAG" >&2
container build -t "$TAG" -f "$OVERLAY_DOCKERFILE" "$OVERLAY_CTX" >&2

echo "$TAG"
