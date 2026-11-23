#!/usr/bin/env bash
# resolve-git-dirs.sh — git stores a container must bind besides its
# workspaces (ADR-0019).
#
# Usage:
#   scripts/resolve-git-dirs.sh <workspace>[:ro] ...
#
# A linked worktree's .git file points into <common-dir>/worktrees/<id>,
# outside the worktree. The common dir is bound at its 1:1 path, once per
# repo and only if no workspace already contains it. It is read-write if
# any non-:ro workspace uses it, else read-only (mounted via rp-fuse).
#
# Outputs (to stdout) one `<common-dir>[:ro]` per line. Warnings go to
# stderr. RP_NO_WORKTREE_BIND=1 disables detection.
set -euo pipefail

[ "${RP_NO_WORKTREE_BIND:-0}" = "1" ] && exit 0

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib-identity.sh"

# Usage: inside <path> <dir> — true if <path> is <dir> or below it.
inside() {
    case "$1/" in "$2"/*) return 0 ;; esac
    return 1
}

paths=()
ro_paths=()  # parallel to paths: 1 if mounted :ro
for entry in "$@"; do
    paths+=("${entry%:ro}")
    if [ "$entry" != "${entry%:ro}" ]; then ro_paths+=(1); else ro_paths+=(0); fi
done

dirs=()   # common dirs, in first-seen order
modes=()  # parallel: rw or ro
for entry in "$@"; do
    p=${entry%:ro}
    mode=rw
    [ "$entry" != "$p" ] && mode=ro

    rp_git_info "$p"
    if [ -z "$RP_GIT_COMMON" ]; then
        top=$(_rp_git -C "$p" rev-parse --path-format=absolute --show-toplevel 2>/dev/null || true)
        if [ -n "$top" ]; then
            echo "rp: warning — $p is a subdirectory of the git worktree $top;" >&2
            echo "    git is not available in the container. Run rp from $top to get git." >&2
        fi
        continue
    fi

    covered=0
    for i in "${!paths[@]}"; do
        inside "$RP_GIT_COMMON" "${paths[$i]}" || continue
        covered=1
        # The common dir is then only reachable read-only, so commits and
        # every other ref or object write from this workspace fail.
        if [ "$mode" = rw ] && [ "${ro_paths[$i]}" = 1 ]; then
            echo "rp: warning — $p is a worktree whose git dir $RP_GIT_COMMON lies inside the" >&2
            echo "    read-only workspace ${paths[$i]}; git can't commit from it. Drop ${paths[$i]}" >&2
            echo "    (rp binds the git dir on its own) or mount it read-write." >&2
        fi
        break
    done
    [ "$covered" -eq 1 ] && continue

    found=0
    for i in "${!dirs[@]}"; do
        if [ "${dirs[$i]}" = "$RP_GIT_COMMON" ]; then
            found=1
            [ "$mode" = rw ] && modes[$i]=rw
        fi
    done
    if [ "$found" -eq 0 ]; then
        dirs+=("$RP_GIT_COMMON")
        modes+=("$mode")
    fi
done

for i in "${!dirs[@]}"; do
    if [ "${modes[$i]}" = ro ]; then
        echo "${dirs[$i]}:ro"
    else
        echo "${dirs[$i]}"
    fi
done
