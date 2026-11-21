#!/usr/bin/env bash
# ADR-0025: workspace lifecycle.
#
# Property: `rp destroy` removes the container and its workspace volumes
# but keeps the repo's memory; `rp run` only hints at orphans; `rp gc`
# lists before it removes, needs --yes without a terminal, and deletes
# repo memory and legacy volume dirs only when asked; `rp recreate`
# migrates a pre-ADR-0024 container's volumes and seeds the repo memory.
#
# RP_GC_SCOPE limits gc to this test's containers and images, so the
# user's own are never touched. RP_VOLUMES_DIR is private to the test.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$REPO_DIR/scripts/lib-identity.sh"

g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

base=$(mk_probe lifecycle)
g init -q "$base/rplife"
(cd "$base/rplife" && "$RP" init >/dev/null)
g -C "$base/rplife" add -A
g -C "$base/rplife" commit -q -m init
g -C "$base/rplife" worktree add -q -b a "$base/rplife-a"
g -C "$base/rplife" worktree add -q -b b "$base/rplife-b"

ca=$(container_name claude-code rplife-a)
cb=$(container_name claude-code rplife-b)
remember_container "$ca"
remember_container "$cb"
V=$RP_VOLUMES_DIR
memory_dir() { echo "$V/repos/$(rp_repo_key "$base/rplife/.git")/claude-memory"; }
ws_dir() { echo "$V/workspaces/$(rp_workspace_key "$1" "$2")"; }
as_coder() { container exec -u coder --workdir /home/coder "$@"; }

# --- destroy ---------------------------------------------------------
cd "$base/rplife-a"
out=$("$RP" create 2>&1) || fail "rp create in rplife-a failed: $out"
container start "$ca" >/dev/null 2>&1 || true
as_coder "$ca" sh -c 'echo kept > .claude-memory/MEMORY.md' || fail "write memory"
image=$(container inspect "$ca" | jq -r '.[0].configuration.image.reference')
[ -d "$(ws_dir "$ca" "$base/rplife-a")" ] || fail "no workspace volume dir before destroy"
"$RP" destroy >/dev/null 2>&1 || fail "rp destroy failed"
[ ! -e "$(ws_dir "$ca" "$base/rplife-a")" ] || fail "destroy kept the workspace volumes"
assert_eq "$(cat "$(memory_dir)/MEMORY.md")" "kept" "destroy keeps the repo memory"
container image inspect "$image" >/dev/null 2>&1 || fail "destroy removed the shared image"

# --- orphan hint -------------------------------------------------------
cd "$base/rplife-b"
out=$("$RP" create 2>&1) || fail "rp create in rplife-b failed: $out"
cd "$base/rplife"
g worktree remove --force "$base/rplife-b"
cd "$base/rplife-a"
out=$("$RP" create 2>&1) || fail "rp create in rplife-a failed: $out"
out=$("$RP" _ensure 2>&1) || fail "rp _ensure failed: $out"
assert_contains "$out" "belong to folders that no longer exist" "orphan hint"
container inspect "$cb" >/dev/null 2>&1 || fail "a normal command removed the orphan"

# --- gc ----------------------------------------------------------------
mkdir -p "$V/repos/gone-00000000/claude-memory" "$V/rp-claude-code-ghost/claude-home"
echo "$base/no-such-repo/.git" > "$V/repos/gone-00000000/.repo"
export RP_GC_SCOPE=rplife

out=$("$RP" gc </dev/null 2>&1) && fail "gc without a terminal or --yes succeeded: $out"
assert_contains "$out" "container $cb" "gc lists the orphaned container"
assert_contains "$out" "workspaces/$(rp_workspace_key "$cb" "$base/rplife-b")" "gc lists its volumes"
assert_contains "$out" "memory    repos/gone-00000000" "gc reports the orphaned memory"
assert_contains "$out" "legacy    rp-claude-code-ghost" "gc reports the legacy dir"
assert_contains "$out" "rerun with --yes" "gc asks for --yes"
container inspect "$cb" >/dev/null 2>&1 || fail "gc removed something without confirmation"

out=$("$RP" gc --yes 2>&1) || fail "rp gc --yes failed: $out"
container inspect "$cb" >/dev/null 2>&1 && fail "gc kept the orphaned container"
[ ! -e "$(ws_dir "$cb" "$base/rplife-b")" ] || fail "gc kept the orphan's volumes"
container inspect "$ca" >/dev/null 2>&1 || fail "gc removed a live container"
[ -d "$V/repos/gone-00000000" ] || fail "gc removed memory without --memory"
[ -d "$V/rp-claude-code-ghost" ] || fail "gc removed a legacy dir without --legacy"

out=$("$RP" gc --yes --memory --legacy 2>&1) || fail "rp gc --memory --legacy failed: $out"
[ ! -e "$V/repos/gone-00000000" ] || fail "gc --memory kept the orphaned memory"
[ ! -e "$V/rp-claude-code-ghost" ] || fail "gc --legacy kept the legacy dir"
[ -f "$(memory_dir)/MEMORY.md" ] || fail "gc removed the memory of a live repo"
unset RP_GC_SCOPE

# --- migration on recreate -------------------------------------------
# Fake a pre-ADR-0024 container: volumes under the container name, auto-
# memory inside ~/.claude, and an empty repo memory to seed.
rm -rf "$(ws_dir "$ca" "$base/rplife-a")" "$(memory_dir)"
mkdir -p "$V/$ca/claude-home/projects/-x/memory"
echo legacy-login > "$V/$ca/claude-home/rp-legacy-marker"
echo legacy-memory > "$V/$ca/claude-home/projects/-x/memory/MEMORY.md"
out=$("$RP" recreate 2>&1) || fail "rp recreate failed: $out"
assert_contains "$out" "moved volumes of $ca" "recreate migrates"
[ ! -e "$V/$ca" ] || fail "legacy dir still there after migration"
container start "$ca" >/dev/null 2>&1 || true
assert_eq "$(as_coder "$ca" cat .claude/rp-legacy-marker 2>&1)" "legacy-login" "login state migrated"
assert_eq "$(as_coder "$ca" cat .claude-memory/MEMORY.md 2>&1)" "legacy-memory" "memory seeded"
assert_eq "$(cat "$(ws_dir "$ca" "$base/rplife-a")/.workspace")" "$base/rplife-a" "workspace metadata"
label=$(container inspect "$ca" | jq -r '.[0].configuration.labels["rp.volume_key"]')
assert_eq "$label" "$(rp_workspace_key "$ca" "$base/rplife-a")" "volume key label"

echo "OK test-lifecycle"
