#!/usr/bin/env bash
# ADR-0021: workspace identity and naming (scripts/lib-identity.sh).
#
# Builds git fixtures for the three worktree layouts and checks names,
# collision handling, lookup by path and on-disk keys. The container list
# is faked, so no container runtime is needed.
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
. "$THIS/../../scripts/lib-identity.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)

fail() { echo "FAIL test-identity: $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }
g init -q "$T/seed"
g -C "$T/seed" commit -q --allow-empty -m init
g -C "$T/seed" branch -q feat

# Layout A: bare repo inside the project dir, worktrees next to it.
mkdir "$T/proja"
g clone -q --bare "$T/seed" "$T/proja/.bare"
printf 'gitdir: ./.bare\n' > "$T/proja/.git"
g -C "$T/proja/.bare" worktree add -q "$T/proja/main" main
g -C "$T/proja/.bare" worktree add -q "$T/proja/feat" feat
mkdir "$T/proja/nested"
g -C "$T/proja/.bare" worktree add -q -b other "$T/proja/nested/main"
# Layout B: plain clone plus a sibling worktree named <repo>-<branch>.
g clone -q "$T/seed" "$T/ProjB"
g -C "$T/ProjB" worktree add -q -b feat-wt "$T/ProjB-feat" origin/feat
mkdir "$T/ProjB/sub"
# Layout C: central bare repo, worktrees elsewhere.
mkdir -p "$T/repos" "$T/src"
g clone -q --bare "$T/seed" "$T/repos/projc.git"
g -C "$T/repos/projc.git" worktree add -q "$T/src/projc-main" main
# Non-git directory with characters that need sanitising.
mkdir "$T/My Dir!"

names() { rp_name_candidates "$1" | paste -sd' ' -; }

# Names
eq "$(names "$T/proja/main")" "proja-main" "layout A worktree"
eq "$(names "$T/proja/feat")" "proja-feat" "layout A worktree 2"
eq "$(names "$T/proja/nested/main")" "proja-main1" "layout A id collision"
eq "$(names "$T/proja")" "proja" "layout A project dir (bare repo, no worktree)"
eq "$(names "$T/ProjB")" "projb" "layout B main worktree"
eq "$(names "$T/ProjB-feat")" "projb-feat projb-projb-feat" "layout B repo prefix stripped"
eq "$(names "$T/ProjB/sub")" "sub" "subdirectory is named like a plain dir"
eq "$(names "$T/src/projc-main")" "projc-main projc-projc-main" "layout C"
eq "$(names "$T/My Dir!")" "my-dir" "non-git, sanitised"
eq "$(rp_slugify '..-Foo_Bar.-')" "foo_bar" "slug trim"

# Free names with collisions (index columns: name, path, agent, explicit)
P=rp-claude-code-
idx=""
eq "$(rp_free_name "$idx" "$P" "$T/ProjB-feat")" "projb-feat" "free: no containers"
idx=$(printf '%s\t/other\tclaude-code\t0\n' "${P}projb-feat")
eq "$(rp_free_name "$idx" "$P" "$T/ProjB-feat")" "projb-projb-feat" "free: stripped name taken"
idx=$(printf '%s\t/other\tclaude-code\t0\n%s\t/x\tclaude-code\t0\n' "${P}projb-feat" "${P}projb-projb-feat")
eq "$(rp_free_name "$idx" "$P" "$T/ProjB-feat")" "projb-projb-feat-2" "free: both taken"
idx=$(printf '%s\t/a\tclaude-code\t0\n%s\t/b\tclaude-code\t0\n' "${P}proja-main" "${P}proja-main-2")
eq "$(rp_free_name "$idx" "$P" "$T/proja/main")" "proja-main-3" "free: numeric suffix"
idx=$(printf '%s\t/a\topencode\t0\n' "rp-opencode-proja-main")
eq "$(rp_free_name "$idx" "$P" "$T/proja/main")" "proja-main" "free: other agent's prefix"

# Lookup by path
W="$T/proja/main"
idx=$(printf '%s\t%s\tclaude-code\t\n' "${P}legacy-name" "$W")
eq "$(rp_find_container "$idx" "$W" claude-code)" "${P}legacy-name" "find: unlabeled legacy container"
eq "$(rp_find_container "$idx" "$W" opencode)" "" "find: agent must match"
eq "$(rp_find_container "$idx" "$T/proja/feat" claude-code)" "" "find: other path"
idx=$(printf '%s\t%s\tclaude-code\t0\n%s\t%s\tclaude-code\t1\n' "${P}proja-main" "$W" "${P}extra" "$W")
eq "$(rp_find_container "$idx" "$W" claude-code)" "${P}proja-main" "find: default wins over --name"
idx=$(printf '%s\t%s\tclaude-code\t1\n%s\t%s\tclaude-code\t1\n' "${P}x" "$W" "${P}y" "$W")
if rp_find_container "$idx" "$W" claude-code >/dev/null 2>&1; then
    fail "find: two --name containers on one path must be ambiguous"
fi

# Keys
rp_git_info "$T/proja/main"; ca=$RP_GIT_COMMON
rp_git_info "$T/proja/feat"; cb=$RP_GIT_COMMON
eq "$ca" "$T/proja/.bare" "common dir layout A"
eq "$(rp_repo_key "$ca")" "$(rp_repo_key "$cb")" "repo key shared by worktrees"
[[ "$(rp_repo_key "$ca")" =~ ^proja-[0-9a-f]{8}$ ]] || fail "repo key format: $(rp_repo_key "$ca")"
rp_git_info "$T/repos/../src/projc-main"
eq "$RP_GIT_COMMON" "" "non-canonical path is not treated as a worktree root"
ka=$(rp_workspace_key "${P}proja-main" "$T/proja/main")
kb=$(rp_workspace_key "${P}proja-main" "$T/elsewhere/main")
[[ "$ka" =~ ^rp-claude-code-proja-main-[0-9a-f]{8}$ ]] || fail "workspace key format: $ka"
[ "$ka" != "$kb" ] || fail "workspace key must differ per path"

echo "OK test-identity"
