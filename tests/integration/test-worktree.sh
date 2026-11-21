#!/usr/bin/env bash
# ADR-0019: git works in a linked-worktree workspace.
#
# Property: the worktree's common dir is bound 1:1, so git in the container
# reads and writes the shared repository, and commits show up on the host.
# A :ro worktree gets a read-only common dir (mounted via rp-fuse).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

base=$(mk_probe worktree)
g init -q "$base/rpwt"
(cd "$base/rpwt" && "$RP" init >/dev/null)
g -C "$base/rpwt" add -A
g -C "$base/rpwt" commit -q -m init
g -C "$base/rpwt" worktree add -q -b feat "$base/rpwt-feat"
ws="$base/rpwt-feat"
common="$base/rpwt/.git"

# (1) Read-write: commit from the container, see it on the host.
cont=$(container_name claude-code rpwt-feat)
remember_container "$cont"
cd "$ws"
out=$("$RP" create 2>&1) || fail "rp create in worktree failed: $out"

ex() { container exec -u coder --workdir "$ws" "$1" sh -c "$2" 2>&1; }

out=$(ex "$cont" 'git status --porcelain') || fail "git status in worktree failed: $out"
assert_eq "$out" "" "clean worktree status"
out=$(ex "$cont" 'echo hi > note.txt && git add note.txt && git -c user.email=t@t -c user.name=t commit -q -m from-container && echo committed') \
    || fail "commit in worktree failed: $out"
assert_contains "$out" "committed" "commit in worktree"
assert_eq "$(g -C "$base/rpwt" log -1 --format=%s feat)" "from-container" "commit visible on host"

# (2) Read-only: git reads work, writes to the common dir fail.
cont_ro=$(container_name claude-code rpwt-ro)
remember_container "$cont_ro"
out=$("$RP" create --name rpwt-ro "$ws:ro" 2>&1) || fail "rp create :ro failed: $out"

out=$(ex "$cont_ro" 'git log -1 --format=%s') || fail "git log in :ro worktree failed: $out"
assert_eq "$out" "from-container" "git log through read-only common dir"
out=$(ex "$cont_ro" "grep ' $common ' /proc/mounts")
assert_contains "$out" "fuse" "read-only common dir is an rp-fuse mount"
out=$(ex "$cont_ro" "touch $common/rp-probe && echo wrote") && fail "write to :ro common dir succeeded: $out"
[ -e "$common/rp-probe" ] && fail "write to :ro common dir reached the host"

echo "OK test-worktree"
