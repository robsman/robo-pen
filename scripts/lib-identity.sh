#!/usr/bin/env bash
# Workspace identity (ADR-0021). Sourced by resolve-recipe-ctx.sh and the
# host tests; defines functions only.
#
# A container is identified by the canonical path of its primary workspace
# (the rp.host_path label). Its name is a readable label derived from the
# git repo and worktree, assigned once at create. On-disk state is keyed
# by path hashes, never by names.

# Run git without inheriting a caller's GIT_DIR / GIT_WORK_TREE.
_rp_git() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git "$@"
}

rp_hash8() {
    printf '%s' "$1" | shasum -a 256 | cut -c1-8
}

# Lowercase (names end up in image tags, which must be lowercase), map
# anything outside [a-z0-9._-] to '-', trim dots and dashes at both ends.
rp_slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' \
        | sed -E 's/^[.-]+//; s/[.-]+$//'
}

# Usage: rp_git_info <canonical-path>
# Sets RP_GIT_COMMON (canonical git common dir) and RP_GIT_WT_ID (worktree
# id, empty for a main worktree). Both stay empty for non-git paths and
# for subdirectories of a worktree, which are named like plain dirs.
rp_git_info() {
    RP_GIT_COMMON=""
    RP_GIT_WT_ID=""
    local path=$1 top gitdir common
    top=$(_rp_git -C "$path" rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || return 0
    [ "$(cd "$top" && pwd -P)" = "$path" ] || return 0
    gitdir=$(_rp_git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 0
    common=$(_rp_git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
    gitdir=$(cd "$gitdir" && pwd -P)
    common=$(cd "$common" && pwd -P)
    RP_GIT_COMMON=$common
    if [ "$gitdir" != "$common" ]; then
        RP_GIT_WT_ID=$(basename "$gitdir")
    fi
}

# Usage: rp_repo_slug <common-dir>
# ~/proj/.git and ~/proj/.bare give "proj", ~/repos/proj.git gives "proj".
rp_repo_slug() {
    local base
    base=$(basename "$1")
    case "$base" in
        .git|.bare) base=$(basename "$(dirname "$1")") ;;
    esac
    rp_slugify "${base%.git}"
}

# Usage: rp_name_candidates <canonical-path>
# Prints candidate names (without the rp-<agent>- prefix), most preferred
# first. The last one is the base for numeric collision suffixes.
rp_name_candidates() {
    local path=$1 slug id stripped
    rp_git_info "$path"
    if [ -z "$RP_GIT_COMMON" ]; then
        slug=$(rp_slugify "$(basename "$path")")
        echo "${slug:-workspace}"
        return
    fi
    slug=$(rp_repo_slug "$RP_GIT_COMMON")
    slug=${slug:-repo}
    if [ -z "$RP_GIT_WT_ID" ]; then
        echo "$slug"
        return
    fi
    id=$(rp_slugify "$RP_GIT_WT_ID")
    # Worktree dirs are often named <repo>-<branch>; avoid proj-proj-main.
    stripped=${id#"$slug"-}
    if [ "$stripped" != "$id" ] && [ -n "$stripped" ]; then
        echo "$slug-$stripped"
    fi
    echo "$slug-${id:-wt}"
}

# Prints one TSV line per container: name, rp.host_path, rp.agent,
# rp.name_explicit. Tests override this function.
rp_container_index() {
    container list -a --format json 2>/dev/null | jq -r '.[] | [
        .configuration.id,
        (.configuration.labels["rp.host_path"] // ""),
        (.configuration.labels["rp.agent"] // ""),
        (.configuration.labels["rp.name_explicit"] // "")
    ] | @tsv'
}

# Usage: rp_find_container <index> <canonical-path> <agent>
# Prints the name of the container for this path and agent, or nothing.
# Several containers can share a path when extra ones were created with
# --name; the one created without --name wins. Returns 1 if that is
# still ambiguous.
rp_find_container() {
    local index=$1 path=$2 agent=$3 all defaults
    all=$(awk -F'\t' -v p="$path" -v a="$agent" '$2 == p && $3 == a { print $1 }' <<<"$index")
    [ -z "$all" ] && return 0
    if [ "$(wc -l <<<"$all")" -eq 1 ]; then
        echo "$all"
        return 0
    fi
    defaults=$(awk -F'\t' -v p="$path" -v a="$agent" '$2 == p && $3 == a && $4 != "1" { print $1 }' <<<"$index")
    if [ -n "$defaults" ] && [ "$(wc -l <<<"$defaults")" -eq 1 ]; then
        echo "$defaults"
        return 0
    fi
    echo "rp: several containers are bound to $path:" >&2
    sed 's/^/  /' <<<"$all" >&2
    echo "    pick one with --name <name> (without the rp-$agent- prefix)" >&2
    return 1
}

# Usage: rp_free_name <index> <prefix> <canonical-path>
# Prints the first candidate name (without prefix) no container holds yet,
# appending -2, -3 ... to the last candidate if all are taken.
rp_free_name() {
    local index=$1 prefix=$2 path=$3 cand last="" n
    _rp_taken() { awk -F'\t' -v n="$prefix$1" '$1 == n { f = 1 } END { exit !f }' <<<"$index"; }
    for cand in $(rp_name_candidates "$path"); do
        last=$cand
        _rp_taken "$cand" || { echo "$cand"; return 0; }
    done
    n=2
    while _rp_taken "$last-$n"; do
        n=$((n + 1))
    done
    echo "$last-$n"
}

# Usage: rp_repo_key <canonical-common-dir>
rp_repo_key() {
    echo "$(rp_repo_slug "$1")-$(rp_hash8 "$1")"
}

# Usage: rp_workspace_key <container-name> <canonical-primary-path>
# The full container name keeps containers of different agents on one
# path apart.
rp_workspace_key() {
    echo "$1-$(rp_hash8 "$2")"
}
