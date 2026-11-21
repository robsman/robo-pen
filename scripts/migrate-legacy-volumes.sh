#!/usr/bin/env bash
# migrate-legacy-volumes.sh — move a pre-ADR-0024 container's volumes to
# the workspace key, called by `rp recreate` between deleting the old
# container and creating the new one (ADR-0025).
#
# Usage:
#   scripts/migrate-legacy-volumes.sh <workspace-dir> <agent-name> <container-name> <workspace-key> <repo-key> <container-user>
#
#   1. $RP_VOLUMES_DIR/<container-name>/ moves to
#      $RP_VOLUMES_DIR/workspaces/<workspace-key>/, so login and history
#      survive.
#   2. Auto-memory under claude-home/projects/*/memory/ is copied into the
#      claude-memory volume (the repo's, or the workspace's outside git),
#      but only while that volume is empty: the first workspace of a repo
#      to migrate seeds its memory, later ones don't merge.
# Does nothing when there is no legacy dir.

set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: migrate-legacy-volumes.sh <workspace-dir> <agent-name> <container-name> <workspace-key> <repo-key> <container-user>" >&2
    exit 2
fi

WORKSPACE=$1
AGENT=$2
CONT_NAME=$3
WORKSPACE_KEY=$4
REPO_KEY=$5
RP_USER=$6

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
VOLUMES_DIR=${RP_VOLUMES_DIR:-$HOME/.local/share/robo-pen/volumes}
legacy="$VOLUMES_DIR/$CONT_NAME"
target="$VOLUMES_DIR/workspaces/$WORKSPACE_KEY"

[ -d "$legacy" ] || exit 0
if [ -e "$target" ]; then
    echo "rp: $target already exists; leaving the old volumes at $legacy ('rp gc --legacy' removes them)" >&2
    exit 0
fi

mkdir -p "$VOLUMES_DIR/workspaces"
mv "$legacy" "$target"
printf '%s\n' "$WORKSPACE" > "$target/.workspace"
echo "rp: moved volumes of $CONT_NAME to workspaces/$WORKSPACE_KEY" >&2

memory=$("$REPO_DIR/scripts/resolve-volumes.sh" "$WORKSPACE" "$AGENT" "$WORKSPACE_KEY" "$REPO_KEY" "$RP_USER" \
    | awk -F'\t' '$3 == "claude-memory" { print $1 }')
[ -n "$memory" ] || exit 0
if [ -n "$(ls -A "$memory" 2>/dev/null)" ]; then
    exit 0
fi
copied=0
for src in "$target"/claude-home/projects/*/memory; do
    [ -d "$src" ] && [ -n "$(ls -A "$src")" ] || continue
    cp -Rn "$src/." "$memory/" || true
    copied=1
done
if [ "$copied" = 1 ]; then
    echo "rp: seeded auto-memory at ${memory#"$VOLUMES_DIR"/} from the old ~/.claude" >&2
fi
