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

if [ -x "$RP_FUSE" ] && [ -f "$CONFIG" ]; then
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
