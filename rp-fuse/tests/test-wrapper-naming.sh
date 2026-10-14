#!/usr/bin/env bash
# Host test for the `rp` wrapper's repo-scoped default container name.
#
# The wrapper derives RP_NAME then execs `just`. We shadow `just` with a
# stub that prints RP_NAME, so we can assert naming WITHOUT building an
# image or starting a container. See ADR-0021.
#
# Covered:
#   1. Worktrees of one repo get <repo>-<worktree>.
#   2. The same worktree name in a DIFFERENT repo gets a different name.
#   3. A plain clone at its top level keeps the short <repo> name.
#   4. A non-git directory keeps basename naming.
#   5. --name still overrides.
#   6. Named recipes (shell/stop/...) use the same default.
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$THIS/../.." && pwd)
RP="$REPO/rp"

if ! command -v git >/dev/null 2>&1; then
    echo "SKIP test-wrapper-naming: git not on PATH"
    exit 0
fi

# macOS /tmp is a symlink to /private/tmp; the wrapper canonicalises with
# `pwd -P`, so resolve the temp root the same way.
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/bin/just" <<'STUB'
#!/usr/bin/env bash
echo "RP_NAME=${RP_NAME:-}"
STUB
chmod +x "$TMP/bin/just"

git_q() { git -c user.email=t@t.test -c user.name=test -c init.defaultBranch=main "$@"; }

name_from_rp() {
    local rundir=$1; shift
    ( cd "$rundir" && PATH="$TMP/bin:$PATH" "$RP" "$@" 2>/dev/null ) \
        | sed -n 's/^RP_NAME=//p'
}

fail() { echo "FAIL test-wrapper-naming: $1" >&2; exit 1; }
expect() { [ "$2" = "$3" ] || fail "$1: got '$2', expected '$3'"; }

# --- Fixture: two bare repos, each with a worktree called `main` ----------
git_q init -q "$TMP/seed"
git_q -C "$TMP/seed" commit -q --allow-empty -m init
for r in proj other; do
    mkdir -p "$TMP/$r"
    git_q clone -q --bare "$TMP/seed" "$TMP/$r/.bare"
    git_q -C "$TMP/$r/.bare" worktree add -q "$TMP/$r/main" main
done

# 1. + 2. Same worktree name, different repos → different container names.
expect "proj worktree"  "$(name_from_rp "$TMP/proj/main" run)"  "proj-main"
expect "other worktree" "$(name_from_rp "$TMP/other/main" run)" "other-main"

# A second worktree of the same repo stays repo-scoped and distinct.
git_q -C "$TMP/proj/.bare" worktree add -q -b feat-x "$TMP/proj/feat-x" main
expect "second worktree" "$(name_from_rp "$TMP/proj/feat-x" run)" "proj-feat-x"

# 3. Plain clone at its top level → short name (unchanged behaviour).
git_q init -q "$TMP/plain"
git_q -C "$TMP/plain" commit -q --allow-empty -m init
expect "plain clone" "$(name_from_rp "$TMP/plain" run)" "plain"

# A subdirectory of a plain clone is still scoped to the repo.
mkdir -p "$TMP/plain/sub"
expect "clone subdir" "$(name_from_rp "$TMP/plain/sub" run)" "plain-sub"

# 4. No git → basename, as before.
mkdir -p "$TMP/notes"
expect "non-git dir" "$(name_from_rp "$TMP/notes" run)" "notes"

# 5. --name wins.
expect "--name override" "$(name_from_rp "$TMP/proj/main" run --name custom)" "custom"

# 6. Named recipes take the same default (they accept no PATH args).
expect "named recipe" "$(name_from_rp "$TMP/proj/main" shell)" "proj-main"

echo "PASS test-wrapper-naming"
