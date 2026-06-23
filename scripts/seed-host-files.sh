#!/usr/bin/env bash
# seed-host-files.sh — copy host files + Keychain entries declared in the
# agent profile's manifest into a freshly-created container. Called by
# the Justfile in _ensure / create AFTER `container create` (and after
# `container start` so `container cp` is allowed for the non-volume
# fallback path). See ADR-0015.
#
# Usage:
#   scripts/seed-host-files.sh <workspace-dir> <agent-name> <container-name> <container-user>
#
# Two manifest sections drive this:
#   - host_files: [{src, dst, if_missing}]
#     `src` is a host path (`~` expands to host's $HOME). `dst` is an
#     absolute in-container path with optional `{{user}}` templating.
#   - host_keychain: [{service, dst, mode, if_missing}]
#     macOS-only. Runs `security find-generic-password -s <service> -w`
#     and writes the result to dst with the given mode.
#
# Destination routing — important: Apple Container's `container cp` writes
# into the image filesystem layer, NOT through any bind mounts. A volume
# mount at /home/<user>/.claude/ would shadow whatever cp put under it.
# So for any dst inside a persistent volume's mount path we MUST write
# directly to the host backing dir at
# $RP_VOLUMES_DIR/<container>/<volume>/<rel-inside-volume>. The volume
# bind reflects those files into the container.
#
# Missing host sources: if_missing=skip (default) → INFO log + continue;
# if_missing=error → exit 1.

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: seed-host-files.sh <workspace-dir> <agent-name> <container-name> <container-user>" >&2
    exit 2
fi

WORKSPACE=$1
AGENT=$2
CONT_NAME=$3
RP_USER=$4

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
RP_FUSE="$REPO_DIR/rp-fuse/rp-fuse-darwin-arm64"

if [ ! -x "$RP_FUSE" ]; then
    exit 0
fi

VOLUMES_DIR=${RP_VOLUMES_DIR:-$HOME/.local/share/robo-pen/volumes}

# Build a volume mount → host-backing lookup. Each line: "<mount>\t<host_dir>".
VOLUME_MAP=$(
    "$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" \
        field volumes 2>/dev/null \
        | while IFS=$'\t' read -r vol_name vol_mount; do
            [ -z "$vol_name" ] && continue
            printf '/home/%s/%s\t%s\n' "$RP_USER" "$vol_mount" "$VOLUMES_DIR/$CONT_NAME/$vol_name"
        done
)

expand_user_template() {
    printf '%s' "${1//\{\{user\}\}/$RP_USER}"
}

expand_tilde() {
    local p=$1
    case "$p" in
        "~"|"~/"*) printf '%s' "$HOME${p#\~}" ;;
        *) printf '%s' "$p" ;;
    esac
}

# resolve_volume_target maps an in-container dst to a host backing path
# if dst falls inside any declared volume's mount path. Else echoes
# empty (caller falls back to `container cp`).
resolve_volume_target() {
    local dst=$1
    while IFS=$'\t' read -r mount host_dir; do
        [ -z "$mount" ] && continue
        if [ "$dst" = "$mount" ] || [ "${dst#"$mount"/}" != "$dst" ]; then
            local rel=${dst#"$mount"}
            rel=${rel#/}
            if [ -n "$rel" ]; then
                printf '%s/%s' "$host_dir" "$rel"
            else
                printf '%s' "$host_dir"
            fi
            return 0
        fi
    done <<<"$VOLUME_MAP"
    printf ''
}

# write_to_volume copies a host source (file or dir) into a host backing
# path. Parent dir created. cp -a preserves perms; chmod afterwards if
# mode given. init.sh's chown step covers ownership on container start.
write_to_volume() {
    local target=$1 host_src=$2 mode=${3:-}
    mkdir -p "$(dirname "$target")"
    if [ -d "$host_src" ]; then
        mkdir -p "$target"
        cp -aR "$host_src/." "$target/"
    else
        cp -a "$host_src" "$target"
    fi
    if [ -n "$mode" ]; then
        chmod "$mode" "$target"
    fi
}

# cp_into_container is the fallback for dsts outside any volume. Apple
# Container's cp requires the container to be running. We start it if
# needed and chown the copy to RP_USER after. The file lives in the
# image layer; lost on destroy, re-copied on next create.
cp_into_container() {
    local host_src=$1 dst=$2 mode=${3:-}
    # Lazy-start: only matters for the non-volume path. _ensure already
    # starts the container; for `rp create` standalone the Justfile
    # explicitly starts before invoking us.
    container exec -u 0 "$CONT_NAME" mkdir -p "$(dirname "$dst")" >/dev/null 2>&1 || true
    container cp "$host_src" "$CONT_NAME:$dst" >/dev/null
    container exec -u 0 "$CONT_NAME" chown -R "$RP_USER:$RP_USER" "$dst" 2>/dev/null || true
    if [ -n "$mode" ]; then
        container exec -u 0 "$CONT_NAME" chmod "$mode" "$dst" 2>/dev/null || true
    fi
}

write_dst() {
    local host_src=$1 dst=$2 mode=${3:-}
    local target
    target=$(resolve_volume_target "$dst")
    if [ -n "$target" ]; then
        write_to_volume "$target" "$host_src" "$mode"
        echo "rp seed: → $dst (volume-backed)" >&2
    else
        cp_into_container "$host_src" "$dst" "$mode"
        echo "rp seed: → $dst (container layer)" >&2
    fi
}

# --- Host files -----------------------------------------------------------
"$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" \
    field host_files 2>/dev/null \
    | while IFS=$'\t' read -r src dst if_missing; do
        [ -z "$src" ] && continue
        host_src=$(expand_tilde "$src")
        expanded_dst=$(expand_user_template "$dst")
        if [ ! -e "$host_src" ]; then
            if [ "$if_missing" = "error" ]; then
                echo "rp seed: host_files: $host_src does not exist (if_missing=error)" >&2
                exit 1
            fi
            echo "rp seed: host_files: $host_src not present, skipping" >&2
            continue
        fi
        echo "rp seed: host_files: $host_src" >&2
        write_dst "$host_src" "$expanded_dst"
    done

# --- Host keychain (macOS only) -------------------------------------------
"$RP_FUSE" profile --workspace "$WORKSPACE" --repo-dir "$REPO_DIR" --agent "$AGENT" \
    field host_keychain 2>/dev/null \
    | while IFS=$'\t' read -r service dst mode if_missing; do
        [ -z "$service" ] && continue
        expanded_dst=$(expand_user_template "$dst")
        if ! command -v security >/dev/null 2>&1; then
            if [ "$if_missing" = "error" ]; then
                echo "rp seed: host_keychain: \`security\` not found (if_missing=error)" >&2
                exit 1
            fi
            echo "rp seed: host_keychain: \`security\` not found, skipping" >&2
            continue
        fi
        if ! cred=$(security find-generic-password -s "$service" -w 2>/dev/null); then
            if [ "$if_missing" = "error" ]; then
                echo "rp seed: host_keychain: service $service not found (if_missing=error)" >&2
                exit 1
            fi
            echo "rp seed: host_keychain: service $service not present, skipping" >&2
            continue
        fi
        tmpf=$(mktemp)
        printf '%s' "$cred" > "$tmpf"
        echo "rp seed: host_keychain: $service" >&2
        write_dst "$tmpf" "$expanded_dst" "$mode"
        rm -f "$tmpf"
    done
