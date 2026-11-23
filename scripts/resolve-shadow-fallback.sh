#!/usr/bin/env bash
# resolve-shadow-fallback.sh — shadow rules for workspaces that have no
# .rp/ of their own (ADR-0023).
#
# Usage:
#   scripts/resolve-shadow-fallback.sh <workspace>[:ro] ...
#
# A linked worktree of a repo that doesn't commit .rp/ takes the repo
# home's .rp/ (rp-fuse rpdir). The container can't see the repo home, so
# its .rp/shadow is captured here, at create, and passed to rp-init as
# RP_SHADOW_FALLBACK: space-separated `<workspace>=<base64 rules>`. rp-fuse
# uses it only while the workspace still has no .rp/; changes to the repo
# home's rules apply on `rp recreate`.
#
# Outputs the env value (possibly empty) on stdout.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
RP_FUSE="$REPO_DIR/rp-fuse/rp-fuse-darwin-arm64"
[ -x "$RP_FUSE" ] || exit 0

out=""
for entry in "$@"; do
    p=${entry%:ro}
    dir=$("$RP_FUSE" rpdir "$p")
    [ "$dir" != "$p/.rp" ] && [ -f "$dir/shadow" ] || continue
    out="${out:+$out }$p=$(base64 < "$dir/shadow" | tr -d '\n')"
done
printf '%s\n' "$out"
