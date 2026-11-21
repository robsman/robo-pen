#!/usr/bin/env bash
# resolve-volumes.sh — translate a profile's `volumes:` manifest section
# into `container create -v <host-dir>:<container-mount>` arguments.
#
# Usage:
#   scripts/resolve-volumes.sh <workspace-dir> <agent-name> <workspace-key> <repo-key> <container-user>
#
# Outputs (to stdout) one volume per line, tab-separated:
#   <host-dir>\t<container-mount>\t<volume-name>
#
# Host backing dirs depend on the volume's scope (ADR-0024; default
# RP_VOLUMES_DIR=$HOME/.local/share/robo-pen/volumes):
#   workspace  $RP_VOLUMES_DIR/workspaces/<workspace-key>/<volume-name>/
#   repo       $RP_VOLUMES_DIR/repos/<repo-key>/<volume-name>/
# An empty <repo-key> (non-git workspace) turns repo scope into workspace
# scope. Next to the volume dirs, each key dir records what it belongs to
# (`.workspace`: the workspace path; `.repo`: the git common dir) so
# `rp gc` can find orphans. Those files sit outside every mount, so the
# agent can't rewrite them. Idempotent — mkdirs only if missing; doesn't
# touch existing contents.
#
# The caller (the Justfile) reads the TSV, builds `-v` args, and forwards
# the volume names + container-mount paths to the in-container init.sh
# via the RP_VOLUMES env so init can chown them to RP_USER and seed
# empty volumes from the image's /usr/local/share/rp/seed/ stash.

set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: resolve-volumes.sh <workspace-dir> <agent-name> <workspace-key> <repo-key> <container-user>" >&2
    exit 2
fi

WORKSPACE=$1
AGENT=$2
WORKSPACE_KEY=$3
REPO_KEY=$4
RP_USER=$5

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
RP_FUSE="$REPO_DIR/rp-fuse/rp-fuse-darwin-arm64"

if [ ! -x "$RP_FUSE" ]; then
    # No host binary → can't resolve the manifest. Caller continues without
    # volumes (downgrades gracefully; profile that needs persistence
    # surfaces the missing-binary error elsewhere via lint).
    exit 0
fi

VOLUMES_DIR=${RP_VOLUMES_DIR:-$HOME/.local/share/robo-pen/volumes}

# key_dir <kind> <key> <meta-file> <meta-value>: creates the key dir and
# its metadata file once, prints the dir.
key_dir() {
    local dir="$VOLUMES_DIR/$1/$2"
    if [ ! -f "$dir/$3" ]; then
        mkdir -p "$dir"
        chmod 0700 "$dir" 2>/dev/null || true
        printf '%s\n' "$4" > "$dir/$3"
    fi
    printf '%s' "$dir"
}

# profile field volumes returns one "name\tmount\tscope" line per volume.
volumes=$("$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" field volumes 2>/dev/null || true)
[ -n "$volumes" ] || exit 0

ws_dir=""
repo_dir=""
while IFS=$'\t' read -r vol_name vol_mount vol_scope; do
    [ -z "$vol_name" ] && continue
    if [ "$vol_scope" = "repo" ] && [ -n "$REPO_KEY" ]; then
        if [ -z "$repo_dir" ]; then
            . "$REPO_DIR/scripts/lib-identity.sh"
            rp_git_info "$WORKSPACE"
            repo_dir=$(key_dir repos "$REPO_KEY" .repo "$RP_GIT_COMMON")
        fi
        host_dir="$repo_dir/$vol_name"
    else
        if [ -z "$ws_dir" ]; then
            ws_dir=$(key_dir workspaces "$WORKSPACE_KEY" .workspace "$WORKSPACE")
        fi
        host_dir="$ws_dir/$vol_name"
    fi
    mkdir -p "$host_dir"
    chmod 0700 "$host_dir" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$host_dir" "/home/$RP_USER/$vol_mount" "$vol_name"
done <<<"$volumes"
