#!/usr/bin/env bash
# ADR-0021: containers are found by path, names come from repo + worktree.
#
# Property: two repos with the same name, each with a worktree named
# <repo>-feat, get distinct readable containers without --name. Recipes
# without --name find the container bound to cwd, and fail cleanly where
# no container is bound.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# Usage: mk_repo <parent> -> <parent>/rpid (committed .rp/) + <parent>/rpid-feat
mk_repo() {
    g init -q "$1/rpid"
    (cd "$1/rpid" && "$RP" init >/dev/null)
    g -C "$1/rpid" add -A
    g -C "$1/rpid" commit -q -m init
    g -C "$1/rpid" worktree add -q -b feat "$1/rpid-feat"
}

a=$(mk_probe id-a)
b=$(mk_probe id-b)
mk_repo "$a"
mk_repo "$b"

c1=$(container_name claude-code rpid-feat)
c2=$(container_name claude-code rpid-rpid-feat)
# Register up front: names are only known for sure after create.
remember_container "$c1"
remember_container "$c2"

cd "$a/rpid-feat"
out=$("$RP" create 2>&1) || fail "rp create in $a/rpid-feat failed: $out"
assert_contains "$out" "Container $c1 created" "first worktree name"

cd "$b/rpid-feat"
out=$("$RP" create 2>&1) || fail "rp create in $b/rpid-feat failed: $out"
assert_contains "$out" "Container $c2 created" "same-named worktree of another repo"

# Recipes without --name address the container bound to cwd.
"$RP" stop >/dev/null 2>&1 || fail "rp stop by path failed"
assert_eq "$(container inspect "$c2" | jq -r '.[0].status.state')" "stopped" "stop hit the cwd container"
assert_eq "$(container inspect "$c1" | jq -r '.[0].status.state')" "running" "other container untouched"

out=$("$RP" create 2>&1) && fail "second rp create on the same path succeeded"
assert_contains "$out" "already exists for $b/rpid-feat" "create refuses a bound path"

"$RP" destroy >/dev/null 2>&1 || fail "rp destroy by path failed"
container inspect "$c2" >/dev/null 2>&1 && fail "destroy left $c2"
container inspect "$c1" >/dev/null 2>&1 || fail "destroy removed the wrong container"

cd "$b/rpid"
out=$("$RP" stop 2>&1) && fail "rp stop without a bound container succeeded"
assert_contains "$out" "no claude-code container for $b/rpid" "lookup-only error"

echo "OK test-identity"
