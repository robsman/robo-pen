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
STRIP_SUDO=$("$RP_FUSE" config --file "$CONFIG" field strip_sudo 2>/dev/null || echo "")

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
# Pull explicitly when the image is not already local — separates pull
# failures (manifest missing, network error, arch mismatch) from Debian-
# probe misses. Skip pull for locally-built images (robo-pen-default,
# images we just built in this script's earlier `build` branch).
# `container image inspect` returns 0 iff the image exists locally.
if ! container image inspect "$SOURCE_REF" >/dev/null 2>&1; then
    if ! pull_err=$(container image pull "$SOURCE_REF" 2>&1); then
        cat >&2 <<MSG
build-project-image: failed to pull base image '$SOURCE_REF':

$pull_err

Common causes: image tag does not exist, no arm64 manifest in the manifest
list, network unreachable, or the registry requires authentication.
MSG
        exit 1
    fi
fi

# Probe for /etc/debian_version (Debian + Debian-derived like Ubuntu set it).
# Use apt-get as a secondary signal — some Ubuntu spins drop the file but
# always have apt-get. Surface stderr from the probe container so a runtime
# crash (entrypoint issue, libc mismatch, arch mismatch) reads as such
# instead of masquerading as "wrong distro". Wrap in `if !` so set -e
# doesn't kill us on the expected failure paths.
if ! probe_err=$(container run --rm --entrypoint=/bin/sh "$SOURCE_REF" -c '
    [ -f /etc/debian_version ] && exit 0
    command -v apt-get >/dev/null 2>&1 && exit 0
    echo "neither /etc/debian_version nor apt-get found" >&2
    exit 1
' 2>&1); then
    if grep -q 'platform linux/arm64' <<<"$probe_err"; then
        cat >&2 <<MSG
build-project-image: base image '$SOURCE_REF' has no linux/arm64 manifest.

$probe_err

Apple Container runs natively on arm64 (Apple Silicon) and does not emulate
amd64-only images. Pick a base that publishes an arm64 manifest list — most
official images do (debian, ubuntu, node:*-bookworm, python:*-slim-bookworm,
mcr.microsoft.com/devcontainers/javascript-node, etc.). The mcr.microsoft.com
/devcontainers/universal image is amd64-only at the time of writing.
MSG
    else
        cat >&2 <<MSG
build-project-image: base image '$SOURCE_REF' rejected:

$probe_err

rp's v1 overlay installs fuse3 via apt-get. Alpine, RHEL, Arch, distroless,
etc. bases are not supported yet. Use a Debian-based image
(debian:bookworm-slim, ubuntu:24.04, node:*-bookworm, python:*-slim-bookworm).

See docs/adr/0006-per-project-images-with-rp-overlay.md for the restriction
and the path to widening it.
MSG
    fi
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

# Volume declarations from the profile manifest (name\tmount, one per
# line). Mount paths are relative to /home/<user>/ and absolute-anchor
# the in-container mount point. Files/instructions whose dst falls
# INSIDE any volume mount path are routed to a seed location at build
# time; rp-init.sh copies them into the mounted volume on first launch
# (volume is empty on first create).
VOLUMES_LINES=$("$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" field volumes || true)
SEED_ROOT=/usr/local/share/rp/seed

# expand_user_template substitutes {{user}} in a string. Returns absolute
# in-container path.
expand_user_template() {
    printf '%s' "${1//\{\{user\}\}/$RP_USER}"
}

# volume_seed_target answers: if $expanded_dst is inside any volume's
# mount path (under /home/$RP_USER/<mount>), echo the seed location and
# the volume name (TSV); else echo empty. Mount comparison is purely
# textual (no symlink resolution) — manifest validation already rejects
# `..` segments.
volume_seed_target() {
    local expanded_dst=$1
    local home_prefix="/home/$RP_USER/"
    case "$expanded_dst" in
        "$home_prefix"*) ;;
        *) return 0 ;;  # outside any volume's possible mount root
    esac
    local rel_to_home=${expanded_dst#"$home_prefix"}
    while IFS=$'\t' read -r vol_name vol_mount; do
        [ -z "$vol_name" ] && continue
        # Match if rel_to_home equals vol_mount or starts with vol_mount/.
        if [ "$rel_to_home" = "$vol_mount" ] || [ "${rel_to_home#"$vol_mount"/}" != "$rel_to_home" ]; then
            local sub=${rel_to_home#"$vol_mount"}
            sub=${sub#/}
            local seed_path="$SEED_ROOT/$vol_name"
            [ -n "$sub" ] && seed_path="$seed_path/$sub"
            printf '%s\t%s' "$seed_path" "$vol_name"
            return 0
        fi
    done <<<"$VOLUMES_LINES"
}

# Ensure the configured user exists. If the base image already has them
# (e.g. node:22-bookworm has `node`), useradd is skipped. Otherwise create
# them with an auto-assigned uid — letting useradd pick avoids collisions
# with existing uid 1000 in devcontainer-style images. The security
# invariants (uid != 0, no sudoers entry) are enforced below regardless of
# which branch ran; if the existing image user has sudo, build fails.
USER_EXIST_CHECK="RUN id -u $RP_USER >/dev/null 2>&1 \\
    || useradd -m -s /bin/bash $RP_USER"

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

# Hardening invariants per ADR-0005 / ADR-0008 invariant 3.
RUN test "\$(id -u $RP_USER)" -ne 0 \\
    || (echo "rp-overlay: user '$RP_USER' is root, refusing" >&2; exit 1)
EOF

# strip_sudo (ADR-0009): if the workspace opted in, run a best-effort strip
# of every sudo grant for the configured user BEFORE the ! grep sudoers
# check. The check stays in place — if strip_sudo missed a path, the build
# still fails with the existing refusal message.
if [ "$STRIP_SUDO" = "true" ]; then
    cat <<EOF
# strip_sudo: opt-in (ADR-0009). Removes every common sudo grant for the
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

cat <<EOF
# Refuse if the configured user has any sudoers entry. Strip comments
# before matching so legitimate base-image comments like
# '# Ditto for GPG agent' in /etc/sudoers don't false-positive when the
# user happens to be named the same as a word in those comments.
RUN if cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null | sed 's/#.*//' \\
        | grep -qE "(^|[[:space:]])${RP_USER}([[:space:]]|\$)"; then \\
        echo "rp-overlay: user '$RP_USER' has a sudoers entry, refusing" >&2; exit 1; \\
    fi

# Mount points for the shadow boundary + agent entrypoint dir. No
# fixed workspace path: with 1:1 binds, the workspace is the host path
# (see ADR-0010 workspace-discovery section).
RUN mkdir -p /var/lib/rp/shadow /usr/local/lib/rp \\
    && chmod 0700 /var/lib/rp \\
    && chown root:root /var/lib/rp /var/lib/rp/shadow

# Pull rp-fuse + init script + setuid bootstrap + tini + container-fundamentals
# fragment from rp-base. The unified ENTRYPOINT is `tini -- rp-init-bootstrap`
# (ADR-0010); we COPY tini explicitly so the overlay works on user-supplied
# bases that don't ship tini. Re-apply the setuid bit because COPY --from can
# strip it on some Docker variants.
COPY --from=rp-base /usr/local/bin/rp-fuse /usr/local/bin/rp-fuse
COPY --from=rp-base /usr/local/bin/rp-init.sh /usr/local/bin/rp-init.sh
COPY --from=rp-base /usr/local/bin/rp-init-bootstrap /usr/local/bin/rp-init-bootstrap
COPY --from=rp-base /usr/bin/tini /usr/local/bin/tini
COPY --from=rp-base /etc/rp/instructions/00-container.md /etc/rp/instructions/00-container.md
RUN chmod 0755 /usr/local/bin/rp-fuse /usr/local/bin/rp-init.sh /usr/local/bin/tini \\
    && chown root:root /usr/local/bin/rp-init-bootstrap \\
    && chmod 4755 /usr/local/bin/rp-init-bootstrap

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

# Profile files (manifest's `files:` section). If a file's `dst` falls
# inside a declared volume's mount path, redirect to the seed location
# under /usr/local/share/rp/seed/<volume>/<rel>; rp-init.sh seeds the
# volume from there on first launch. Files outside any volume go
# straight to their absolute in-container path as before.
while IFS=$'\t' read -r src dst; do
    [ -z "$src" ] && continue
    expanded_dst=$(expand_user_template "$dst")
    seed_pair=$(volume_seed_target "$expanded_dst")
    if [ -n "$seed_pair" ]; then
        seed_path=${seed_pair%%$'\t'*}
        vol_name=${seed_pair##*$'\t'}
        parent_dir=$(dirname "$seed_path")
        printf '# files[].dst routed to seed for volume %s\n' "$vol_name"
        printf 'RUN mkdir -p %s\n' "$parent_dir"
        printf 'COPY agent/files/%s %s\n' "$src" "$seed_path"
    else
        parent_dir=$(dirname "$expanded_dst")
        printf 'RUN mkdir -p %s && chown %s:%s %s\n' "$parent_dir" "$RP_USER" "$RP_USER" "$parent_dir"
        printf 'COPY --chown=%s:%s agent/files/%s %s\n' "$RP_USER" "$RP_USER" "$src" "$expanded_dst"
    fi
done <<<"$FILES_LINES"

cat <<EOF

# Most agent installers (claude.ai, opencode.ai) drop their binary into
# \$HOME/.local/bin. Make sure that's on PATH for every container exec; the
# default Dockerfile sets this for the robo-pen-default image, but overlays
# applied to arbitrary user images need an explicit ENV here too.
ENV PATH=/home/$RP_USER/.local/bin:\$PATH

# Run the profile's install.sh as the container user.
USER $RP_USER
COPY --chown=$RP_USER:$RP_USER agent/install.sh /tmp/agent-install.sh
RUN bash /tmp/agent-install.sh && rm /tmp/agent-install.sh

USER root
EOF

if [ -n "$INSTRUCTIONS_DST" ]; then
    expanded_inst=$(expand_user_template "$INSTRUCTIONS_DST")
    seed_pair=$(volume_seed_target "$expanded_inst")
    if [ -n "$seed_pair" ]; then
        # instructions_dst is inside a volume → seed location; rp-init.sh
        # will copy it into the mounted volume on first launch.
        seed_path=${seed_pair%%$'\t'*}
        vol_name=${seed_pair##*$'\t'}
        seed_dir=$(dirname "$seed_path")
        cat <<EOF
# Compose agent instructions into the seed location for volume $vol_name
# (instructions_dst falls inside the volume's mount path).
RUN mkdir -p $seed_dir \\
    && awk 'FNR==1 && NR>1 {print ""} {print}' /etc/rp/instructions/*.md \\
        > $seed_path
EOF
    else
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
fi

cat <<EOF

WORKDIR /home/$RP_USER
USER $RP_USER

# Re-assert the unified entry point. The overlay is the last layer applied
# to the project image, so this ENTRYPOINT wins over any base-image or
# user-Dockerfile ENTRYPOINT. See ADR-0010. tini is PID 1, our bootstrap
# is its only child, escalates via setuid and exec's rp-init.sh.
ENTRYPOINT ["/usr/local/bin/tini", "--", "/usr/local/bin/rp-init-bootstrap"]
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
