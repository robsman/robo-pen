#!/usr/bin/env bash
# resolve-workspace-name.sh — derive the default container slug and the
# repo slug for a workspace directory.
#
# Usage:
#   scripts/resolve-workspace-name.sh <workspace-dir>
#
# Emits two shell assignments on stdout (printf %q quoted):
#   RP_REPO_SLUG     slug of the repository the workspace belongs to
#   RP_DEFAULT_NAME  default container slug (what --name overrides)
#
# Naming is repo-scoped so that sibling worktrees of DIFFERENT repos never
# land on the same container name. Checking out `main` in two repos used to
# yield `rp-<agent>-main` twice; it now yields `<repo>-main` each time.
#
#   ~/Projects/proj/.bare + ~/Projects/proj/main -> proj-main   (repo proj)
#   ~/Projects/other/main                        -> other-main  (repo other)
#   ~/Projects/proj  (plain clone, at top level) -> proj        (repo proj)
#   ~/notes          (no git)                    -> notes       (repo notes)
#
# The workspace slug is dropped when it equals the repo slug, so a plain
# clone keeps the short name it has always had.
set -euo pipefail

WS=${1:?usage: resolve-workspace-name.sh <workspace-dir>}
WS=$(cd "$WS" 2>/dev/null && pwd -P) || {
    echo "resolve-workspace-name.sh: not a directory: $1" >&2
    exit 2
}

# Container names accept [A-Za-z0-9._-]; anything else becomes a dash, and
# leading/trailing dots and dashes are trimmed (a leading dot would give
# `.bare` a hidden-looking container name).
slugify() {
    printf '%s' "$1" | LC_ALL=C sed -e 's/[^A-Za-z0-9._-]/-/g' -e 's/^[.-]*//' -e 's/[.-]*$//'
}

# The common git dir identifies the repository: it is shared by every
# worktree of that repo and differs between repos. Derive the repo root
# from it rather than from the workspace path, which is the worktree.
common=$(git -C "$WS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""

repo_root=""
if [ -n "$common" ] && [ -d "$common" ]; then
    case "$common" in
        # Submodule: <super>/.git/modules/<sub> — the superproject is the repo.
        */.git/modules/*) repo_root=${common%%/.git/modules/*} ;;
        # Plain clone: <top>/.git
        */.git)           repo_root=${common%/.git} ;;
        # Bare-repo layout: <proj>/.bare (or any other dir name).
        *)                repo_root=$(dirname "$common") ;;
    esac
    repo_root=$(cd "$repo_root" 2>/dev/null && pwd -P) || repo_root=""
fi

ws_slug=$(slugify "$(basename "$WS")")
[ -n "$ws_slug" ] && [ "$ws_slug" != "/" ] || ws_slug=workspace

if [ -n "$repo_root" ]; then
    repo_slug=$(slugify "$(basename "$repo_root")")
fi
[ -n "${repo_slug:-}" ] || repo_slug=$ws_slug

if [ "$repo_slug" = "$ws_slug" ]; then
    default_name=$repo_slug
else
    default_name="${repo_slug}-${ws_slug}"
fi

printf 'RP_REPO_SLUG=%q\n' "$repo_slug"
printf 'RP_DEFAULT_NAME=%q\n' "$default_name"
