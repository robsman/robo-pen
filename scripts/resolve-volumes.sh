#!/usr/bin/env bash
# resolve-volumes.sh — translate a profile's `volumes:` manifest section
# into `container create -v <host-dir>:<container-mount>` arguments.
#
# Usage:
#   scripts/resolve-volumes.sh <workspace-dir> <agent-name> <container-name> <container-user>
#
# Outputs (to stdout) one volume per line, tab-separated:
#   <host-dir>\t<container-mount>\t<volume-name>
#
# Also creates each host backing dir on disk
# ($RP_VOLUMES_DIR/<container-name>/<volume-name>/, default
# RP_VOLUMES_DIR=$HOME/.local/share/robo-pen/volumes). Idempotent —
# mkdirs only if missing; doesn't touch existing contents.
#
# The caller (the Justfile) reads the TSV, builds `-v` args, and forwards
# the volume names + container-mount paths to the in-container init.sh
# via the RP_VOLUMES env so init can chown them to RP_USER and seed
# empty volumes from the image's /usr/local/share/rp/seed/ stash.

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: resolve-volumes.sh <workspace-dir> <agent-name> <container-name> <container-user>" >&2
    exit 2
fi

WORKSPACE=$1
AGENT=$2
CONT_NAME=$3
RP_USER=$4

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
RP_FUSE="$REPO_DIR/rp-fuse/rp-fuse-darwin-arm64"

if [ ! -x "$RP_FUSE" ]; then
    # No host binary → can't resolve the manifest. Caller continues without
    # volumes (downgrades gracefully; profile that needs persistence
    # surfaces the missing-binary error elsewhere via lint).
    exit 0
fi

VOLUMES_DIR=${RP_VOLUMES_DIR:-$HOME/.local/share/robo-pen/volumes}

# profile field volumes returns one "name\tmount" line per declared volume.
"$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" field volumes 2>/dev/null \
    | while IFS=$'\t' read -r vol_name vol_mount; do
        [ -z "$vol_name" ] && continue
        host_dir="$VOLUMES_DIR/$CONT_NAME/$vol_name"
        mkdir -p "$host_dir"
        chmod 0700 "$host_dir" 2>/dev/null || true
        cont_mount="/home/$RP_USER/$vol_mount"
        printf '%s\t%s\t%s\n' "$host_dir" "$cont_mount" "$vol_name"
    done
