#!/usr/bin/env bash
# ADR-0019: which git stores a container binds (scripts/resolve-git-dirs.sh).
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
R="$THIS/../../scripts/resolve-git-dirs.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)

fail() { echo "FAIL test-git-dirs: $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
run() { "$R" "$@" 2>/dev/null | paste -sd' ' -; }

g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }
g init -q "$T/seed"
g -C "$T/seed" commit -q --allow-empty -m init
g -C "$T/seed" branch -q feat

# Layout A
mkdir "$T/proja"
g clone -q --bare "$T/seed" "$T/proja/.bare"
printf 'gitdir: ./.bare\n' > "$T/proja/.git"
g -C "$T/proja/.bare" worktree add -q "$T/proja/main" main
g -C "$T/proja/.bare" worktree add -q "$T/proja/feat" feat
# Layout B
g clone -q "$T/seed" "$T/projb"
g -C "$T/projb" worktree add -q -b feat-wt "$T/projb-feat" origin/feat
mkdir "$T/projb/sub"
# Layout C
mkdir -p "$T/repos" "$T/src"
g clone -q --bare "$T/seed" "$T/repos/projc.git"
g -C "$T/repos/projc.git" worktree add -q "$T/src/projc-main" main
mkdir "$T/plain"

eq "$(run "$T/proja/main")" "$T/proja/.bare" "layout A worktree"
eq "$(run "$T/projb-feat")" "$T/projb/.git" "layout B worktree"
eq "$(run "$T/src/projc-main")" "$T/repos/projc.git" "layout C worktree"
eq "$(run "$T/proja/main" "$T/proja/feat")" "$T/proja/.bare" "two worktrees, one bind"
eq "$(run "$T/proja/main:ro")" "$T/proja/.bare:ro" "all :ro -> read-only"
eq "$(run "$T/proja/main:ro" "$T/proja/feat")" "$T/proja/.bare" "one writable user -> read-write"
eq "$(run "$T/proja/feat" "$T/proja/main:ro")" "$T/proja/.bare" "order does not matter"
eq "$(run "$T/proja/main" "$T/src/projc-main:ro")" "$T/proja/.bare $T/repos/projc.git:ro" "one bind per repo"
eq "$(run "$T/projb")" "" "plain clone: .git is inside the workspace"
eq "$(run "$T/projb-feat" "$T/projb")" "" "common dir inside another workspace"
eq "$(run "$T/plain")" "" "non-git dir"
eq "$(run "$T/projb/sub")" "" "subdirectory gets no git"
"$R" "$T/projb/sub" 2>&1 >/dev/null | grep -q "subdirectory of the git worktree $T/projb" \
    || fail "subdirectory warning missing"
eq "$(RP_NO_WORKTREE_BIND=1 run "$T/proja/main")" "" "opt-out"

# A worktree with its main checkout mounted `:ro`: the git dir is inside
# a read-only workspace, so the worktree can't commit. Warn; a writable
# main is fine.
eq "$(run "$T/projb-feat" "$T/projb:ro")" "" "common dir inside a read-only workspace"
"$R" "$T/projb-feat" "$T/projb:ro" 2>&1 >/dev/null | grep -q "git can't commit from it" \
    || fail "read-only git dir warning missing"
[ -z "$("$R" "$T/projb-feat" "$T/projb" 2>&1 >/dev/null)" ] \
    || fail "warning for a read-write main checkout"

echo "OK test-git-dirs"
