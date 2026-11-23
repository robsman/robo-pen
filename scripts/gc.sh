#!/usr/bin/env bash
# gc.sh — remove what short-lived workspaces leave behind (ADR-0025).
#
# Usage:
#   scripts/gc.sh [--yes] [--memory] [--legacy]
#
# Env: RP_GC_KEEP_TAG (current base image tag), RP_GC_BASE_IMAGES
# (space-separated base image repos to sweep old tags of, e.g.
# "rp-system rp-default").
#
# Removes, after showing the list and asking (--yes skips the prompt):
#   - containers whose rp.host_path no longer exists, with their
#     workspace volumes
#   - workspace volume dirs whose recorded path no longer exists
#   - project images (rp-img-*, rp-src-*, legacy *:latest-rp) and old
#     base image tags that no remaining container uses
# Reports but keeps unless asked:
#   - repo volume dirs (auto-memory) whose git common dir is gone: --memory
#   - legacy per-container volume dirs (ADR-0014 layout) whose container
#     is gone; they carry no path, so their origin is unknown: --legacy
#
# A path on an unmounted drive looks deleted, which is why nothing here
# runs automatically.
#
# RP_GC_SCOPE (tests only): an ERE; containers and images whose name
# doesn't match are left alone, so a test run can't touch the user's own.

set -euo pipefail

yes=0 memory=0 legacy=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) yes=1 ;;
        --memory) memory=1 ;;
        --legacy) legacy=1 ;;
        *) echo "usage: rp gc [--yes] [--memory] [--legacy]" >&2; exit 2 ;;
    esac
done

VOLUMES_DIR=${RP_VOLUMES_DIR:-$HOME/.local/share/robo-pen/volumes}
KEEP_TAG=${RP_GC_KEEP_TAG:-latest}
BASE_IMAGES=${RP_GC_BASE_IMAGES:-rp-system rp-default}
SCOPE=${RP_GC_SCOPE:-}
in_scope() { [ -z "$SCOPE" ] || [[ "$1" =~ $SCOPE ]]; }

# One row per container: name, image ref (normalised), host path.
containers=$(container list -a --format json 2>/dev/null | jq -r '.[] | [
    .configuration.id,
    (.configuration.image.reference | sub("^docker.io/library/"; "")),
    (.configuration.labels["rp.host_path"] // "")
] | @tsv')

plan=()   # "kind<TAB>target<TAB>reason", removed on confirmation
kept=()   # same shape, reported only
gone_containers=" "

while IFS=$'\t' read -r name _ path; do
    [ -z "$name" ] || [ -z "$path" ] && continue
    if [ ! -d "$path" ] && in_scope "$name"; then
        plan+=("container"$'\t'"$name"$'\t'"folder gone: $path")
        gone_containers+="$name "
    fi
done <<<"$containers"

for dir in "$VOLUMES_DIR"/workspaces/*/; do
    [ -d "$dir" ] || continue
    dir=${dir%/}
    path=$(cat "$dir/.workspace" 2>/dev/null || true)
    if [ -n "$path" ] && [ ! -e "$path" ]; then
        plan+=("volumes"$'\t'"$dir"$'\t'"folder gone: $path")
    fi
done

for dir in "$VOLUMES_DIR"/repos/*/; do
    [ -d "$dir" ] || continue
    dir=${dir%/}
    common=$(cat "$dir/.repo" 2>/dev/null || true)
    if [ -n "$common" ] && [ ! -e "$common" ]; then
        entry="memory"$'\t'"$dir"$'\t'"repo gone: $common"
        if [ "$memory" = 1 ]; then plan+=("$entry"); else kept+=("$entry"); fi
    fi
done

for dir in "$VOLUMES_DIR"/*/; do
    [ -d "$dir" ] || continue
    dir=${dir%/}
    name=${dir##*/}
    case "$name" in workspaces|repos) continue ;; esac
    if awk -F'\t' -v n="$name" '$1 == n { found = 1 } END { exit !found }' <<<"$containers" \
        && [[ "$gone_containers" != *" $name "* ]]; then
        continue
    fi
    entry="legacy"$'\t'"$dir"$'\t'"pre-worktree volumes, origin unknown"
    if [ "$legacy" = 1 ]; then plan+=("$entry"); else kept+=("$entry"); fi
done

# Images used by the containers that stay.
in_use=$(awk -F'\t' -v gone="$gone_containers" 'index(gone, " " $1 " ") == 0 { print $2 }' <<<"$containers" | sort -u)
while read -r repo tag; do
    ref="$repo:$tag"
    case "$repo:$tag" in
        rp-img-*|rp-src-*|*:latest-rp) ;;
        *)
            # Old base image tags. Always keep the current pin and `latest`
            # (last-known-good fallback).
            [[ " $BASE_IMAGES " == *" $repo "* ]] || continue
            [ "$tag" = "$KEEP_TAG" ] || [ "$tag" = latest ] && continue
            ;;
    esac
    grep -qxF "$ref" <<<"$in_use" && continue
    in_scope "$ref" || continue
    plan+=("image"$'\t'"$ref"$'\t'"unused")
done < <(container image list 2>/dev/null | awk 'NR>1 && $1 != "" { print $1, $2 }')

show() {
    local entry kind target reason
    for entry in "$@"; do
        IFS=$'\t' read -r kind target reason <<<"$entry"
        printf '  %-9s %s  (%s)\n' "$kind" "${target#"$VOLUMES_DIR"/}" "$reason"
    done
}

if [ "${#kept[@]}" -gt 0 ]; then
    echo "rp gc: keeping (pass --memory / --legacy to remove):"
    show "${kept[@]}"
fi
if [ "${#plan[@]}" -eq 0 ]; then
    echo "rp gc: nothing to remove"
    exit 0
fi
echo "rp gc: will remove (volume paths relative to $VOLUMES_DIR):"
show "${plan[@]}"

if [ "$yes" != 1 ]; then
    if [ ! -t 0 ]; then
        echo "rp gc: no terminal to confirm on; rerun with --yes" >&2
        exit 1
    fi
    printf 'Proceed? [y/N] '
    read -r answer || answer=""
    case "$answer" in y|Y|yes) ;; *) echo "rp gc: aborted"; exit 1 ;; esac
fi

# Containers first: their images become removable only once they are gone.
failed=0
for entry in "${plan[@]}"; do
    IFS=$'\t' read -r kind target _ <<<"$entry"
    case "$kind" in
        container)
            container delete --force "$target" >/dev/null 2>&1 || { echo "rp gc: WARN failed to remove container $target" >&2; failed=1; } ;;
    esac
done
for entry in "${plan[@]}"; do
    IFS=$'\t' read -r kind target _ <<<"$entry"
    case "$kind" in
        volumes|memory|legacy)
            rm -rf "$target" || { echo "rp gc: WARN failed to remove $target" >&2; failed=1; } ;;
        image)
            container image rm "$target" >/dev/null 2>&1 || { echo "rp gc: WARN failed to remove image $target" >&2; failed=1; } ;;
    esac
done
echo "rp gc: done"
exit "$failed"
