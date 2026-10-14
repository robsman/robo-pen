#!/usr/bin/env bash
# Host test for the `rp` wrapper's git-worktree auto-bind.
#
# The wrapper computes the workspace bind list (RP_PATHS_RAW) then execs
# `just`. We shadow `just` with a stub that just prints the env the wrapper
# handed it, so we can assert the bind list WITHOUT building an image or
# starting a container.
#
# Covered:
#   1. From inside a linked worktree, the common git dir is auto-appended.
#   2. RP_NO_WORKTREE_BIND=1 suppresses the auto-bind.
#   3. A normal (non-worktree) repo is left with a single bind.
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$THIS/../.." && pwd)
RP="$REPO/rp"

if ! command -v git >/dev/null 2>&1; then
    echo "SKIP test-wrapper-worktree: git not on PATH"
    exit 0
fi

# macOS /tmp is a symlink to /private/tmp; the wrapper canonicalises with
# `pwd -P`, so resolve the temp root the same way to compare like-for-like.
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

# Stub `just`: echo the wrapper's resolved context and exit before any real
# container work. Bracket RP_PATHS_RAW so the test can extract it verbatim.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/just" <<'STUB'
#!/usr/bin/env bash
echo "RP_PATHS_BEGIN"
printf '%s' "${RP_PATHS_RAW:-}"
echo "RP_PATHS_END"
STUB
chmod +x "$TMP/bin/just"

git_q() { git -c user.email=t@t.test -c user.name=test -c init.defaultBranch=main "$@"; }

# Extract the newline-separated path list the wrapper produced. Args after
# the recipe name are the rp invocation; run from $rundir.
paths_from_rp() {
    local rundir=$1; shift
    ( cd "$rundir" && PATH="$TMP/bin:$PATH" "$RP" "$@" 2>/dev/null ) \
        | awk '/RP_PATHS_BEGIN/{f=1;next} /RP_PATHS_END/{f=0} f'
}

fail() { echo "FAIL test-wrapper-worktree: $1" >&2; exit 1; }

# --- Fixture: bare repo + one linked worktree (the user's layout) ----------
git_q init -q "$TMP/seed"
git_q -C "$TMP/seed" commit -q --allow-empty -m init
mkdir -p "$TMP/proj"
git_q clone -q --bare "$TMP/seed" "$TMP/proj/.bare"
git_q -C "$TMP/proj/.bare" worktree add -q "$TMP/proj/main" main

WT=$(cd "$TMP/proj/main" && pwd -P)
BARE=$(cd "$TMP/proj/.bare" && pwd -P)

# 1. Worktree → common git dir auto-appended.
got=$(paths_from_rp "$WT" run)
expected=$(printf '%s\n%s' "$WT" "$BARE")
[ "$got" = "$expected" ] || fail "worktree bind list wrong. got:
$got
expected:
$expected"

# 2. Opt-out env var suppresses the auto-bind.
got=$( cd "$WT" && RP_NO_WORKTREE_BIND=1 PATH="$TMP/bin:$PATH" "$RP" run 2>/dev/null \
        | awk '/RP_PATHS_BEGIN/{f=1;next} /RP_PATHS_END/{f=0} f' )
[ "$got" = "$WT" ] || fail "RP_NO_WORKTREE_BIND=1 should yield a single bind, got:
$got"

# 3. Normal repo (git dir lives inside the workspace) → single bind, no append.
git_q init -q "$TMP/normal"
git_q -C "$TMP/normal" commit -q --allow-empty -m init
NORMAL=$(cd "$TMP/normal" && pwd -P)
got=$(paths_from_rp "$NORMAL" run)
[ "$got" = "$NORMAL" ] || fail "normal repo should yield a single bind, got:
$got"

echo "PASS test-wrapper-worktree"
