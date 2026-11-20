#!/usr/bin/env bash
# ADR-0020: git configuration for FUSE-shadowed workspaces.
#
# Property: inside the container, git works on the bind-mounted repo as the
# non-root user (no dubious-ownership abort), and `git status` neither
# reports untouched files as modified nor rewrites the host's index.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe git-config)
cd "$ws"
git init -q
"$RP" init >/dev/null
echo hello > tracked.txt
git add -A
git -c user.email=t@t -c user.name=t commit -q -m init
index_before=$(shasum "$ws/.git/index")

cont=$(rp_create_and_start git-config)

out=$(container exec -u coder "$cont" git config --system --list 2>&1)
assert_contains "$out" "safe.directory=*" "safe.directory"
assert_contains "$out" "core.checkstat=minimal" "core.checkStat"
assert_contains "$out" "gc.worktreepruneexpire=never" "gc.worktreePruneExpire"

out=$(container exec -u coder "$cont" printenv GIT_OPTIONAL_LOCKS 2>&1)
assert_eq "$out" "0" "GIT_OPTIONAL_LOCKS"

out=$(container exec -u coder --workdir "$ws" "$cont" git status --porcelain 2>&1) \
    || fail "git status failed in container: $out"
assert_eq "$out" "" "clean status inside container"

assert_eq "$(shasum "$ws/.git/index")" "$index_before" "host index untouched by git status"

echo "OK test-git-config"
