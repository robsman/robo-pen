#!/usr/bin/env bash
# resolve-create-args.sh — translate .rp/config.yaml + agent profile into
# extra args for `container create` and env-var lines for rp-init.sh.
#
# Usage:
#   eval "$(scripts/resolve-create-args.sh <workspace-dir>)"
#
# Defines two shell variables in the caller's env:
#   CREATE_FLAGS — extra flags string (e.g. "--memory 4G --cpus 2")
#   CONTAINER_ENV — extra `-e VAR` flags (forwards host values into the container)
#
# Empty / missing config.yaml yields default behavior: the claude-code profile's
# env allow-list (ANTHROPIC_API_KEY) is forwarded.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: resolve-create-args.sh <workspace-dir>" >&2
    exit 2
fi

WORKSPACE=$1
CONFIG="$WORKSPACE/.rp/config.yaml"

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
RP_FUSE="$REPO_DIR/rp-fuse/rp-fuse-darwin-arm64"

CREATE_FLAGS=""
CONTAINER_ENV=""

if [ -x "$RP_FUSE" ]; then
    mem=$("$RP_FUSE" config --file "$CONFIG" field resources.memory 2>/dev/null || true)
    if [ -n "$mem" ]; then
        CREATE_FLAGS="$CREATE_FLAGS --memory $mem"
    fi
    cpus=$("$RP_FUSE" config --file "$CONFIG" field resources.cpus 2>/dev/null || true)
    if [ -n "$cpus" ]; then
        CREATE_FLAGS="$CREATE_FLAGS --cpus $cpus"
    fi
    cache=$("$RP_FUSE" config --file "$CONFIG" field fuse.cache 2>/dev/null || true)
    if [ -n "$cache" ]; then
        CONTAINER_ENV="$CONTAINER_ENV -e RP_CACHE=$cache"
    fi
fi

# host_path_aliases: each entry is `~/sub/path` on the host. Expand ~ to
# host's $HOME and compute the container-side target as /home/<user>/<sub/path>.
# Forward as comma-separated `host:container` pairs; rp-init.sh creates
# each symlink inside the container.
if [ -x "$RP_FUSE" ] && [ -n "${HOME:-}" ]; then
    aliases=$("$RP_FUSE" config --file "$CONFIG" field host_path_aliases 2>/dev/null || true)
    if [ -n "$aliases" ]; then
        # User from earlier in this script: $RP_USER_VAL.
        joined=""
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            # Strip leading ~ and the optional /.
            rel=${entry#\~}
            rel=${rel#/}
            host_path="$HOME"
            [ -n "$rel" ] && host_path="$HOME/$rel"
            user_for_path=${RP_USER_VAL:-coder}
            cont_path="/home/${user_for_path}"
            [ -n "$rel" ] && cont_path="/home/${user_for_path}/$rel"
            if [ -n "$joined" ]; then
                joined="${joined},"
            fi
            joined="${joined}${host_path}:${cont_path}"
        done <<<"$aliases"
        if [ -n "$joined" ]; then
            CONTAINER_ENV="$CONTAINER_ENV -e RP_PATH_ALIASES=$joined"
        fi
    fi
fi

# Host aliases (`host_aliases:` in config + the always-on
# `host.containers.internal`). Apple Container has no `--add-host`
# equivalent, so we forward the list as RP_HOST_ALIASES and let
# rp-init.sh append /etc/hosts entries at startup. The literal
# "host-gateway" gets resolved to the default-route gateway IP inside
# the container.
#
# Format: comma-separated `name=ip` pairs (no whitespace).
if [ -x "$RP_FUSE" ]; then
    aliases=$("$RP_FUSE" config --file "$CONFIG" field host_aliases 2>/dev/null || true)
    if [ -n "$aliases" ]; then
        joined=""
        while IFS='=' read -r alias_name alias_ip; do
            [ -z "$alias_name" ] && continue
            if [ -n "$joined" ]; then
                joined="${joined},"
            fi
            joined="${joined}${alias_name}=${alias_ip}"
        done <<<"$aliases"
        if [ -n "$joined" ]; then
            CONTAINER_ENV="$CONTAINER_ENV -e RP_HOST_ALIASES=$joined"
        fi
    fi
fi

# Forward the configured container user so rp-init.sh can re-validate the
# shadow-boundary invariants (uid != 0, not in sudoers) at runtime — ADR-0008
# invariant 3 belt-and-braces.
if [ -x "$RP_FUSE" ]; then
    RP_USER_CFG=$("$RP_FUSE" config --file "$CONFIG" field user 2>/dev/null || echo "")
    RP_USER_VAL=${RP_USER_CFG:-coder}
    CONTAINER_ENV="$CONTAINER_ENV -e RP_USER=$RP_USER_VAL"
fi

# allow_sudo (per-workspace opt-in). Bypasses the runtime "no sudo"
# refusal in rp-init.sh, matching the build-time skip in
# build-project-image.sh when the same field is set. See ADR-0018.
if [ -x "$RP_FUSE" ]; then
    allow_sudo=$("$RP_FUSE" config --file "$CONFIG" field allow_sudo 2>/dev/null || true)
    if [ "$allow_sudo" = "true" ]; then
        CONTAINER_ENV="$CONTAINER_ENV -e RP_ALLOW_SUDO=1"
    fi
fi

# Forward RP_DEBUG if set in the host shell. Lets the user diagnose a
# specific session without baking debug into config: `RP_DEBUG=1 rp run`.
if [ "${RP_DEBUG:-}" = "1" ]; then
    CONTAINER_ENV="$CONTAINER_ENV -e RP_DEBUG=1"
fi

# Forward each env var declared in the agent profile's manifest. Missing
# values on the host are silently skipped — `container create -e VAR`
# with no value forwards whatever (or nothing) the host has.
if [ -x "$RP_FUSE" ]; then
    AGENT=$("$RP_FUSE" config --file "$CONFIG" field agent 2>/dev/null || echo "claude-code")
    if env_list=$("$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" field env 2>/dev/null); then
        while IFS= read -r v; do
            [ -z "$v" ] && continue
            CONTAINER_ENV="$CONTAINER_ENV -e $v"
        done <<<"$env_list"
    fi
fi

# Emit lines for `eval`.
printf "CREATE_FLAGS=%q\n" "$CREATE_FLAGS"
printf "CONTAINER_ENV=%q\n" "$CONTAINER_ENV"
