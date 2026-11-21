#!/usr/bin/env bash
# Property: `rp create --name N path1 path2` mounts two FUSE-shadowed
# workspaces in one container, each with its own shadow store under
# /var/lib/rp/shadow/<sha8>/.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws_a=$(mk_probe multi-a)
ws_b=$(mk_probe multi-b)

cd "$ws_a"; "$RP" init >/dev/null
cd "$ws_b"; "$RP" init >/dev/null

echo "from-a" > "$ws_a/marker.txt"
echo "from-b" > "$ws_b/marker.txt"

cont=$(container_name claude-code multi-a)
container delete --force "$cont" >/dev/null 2>&1 || true
remember_container "$cont"

# Name derives from basename(first path) = "multi-a"; cwd irrelevant.
"$RP" create --name multi-a "$ws_a" "$ws_b" >/dev/null 2>&1 \
    || fail "rp create --name multi-a $ws_a $ws_b failed"
container start "$cont" >/dev/null 2>&1 || fail "container start $cont failed"

# Wait for both FUSE mounts to appear.
n=0
for _ in $(seq 1 30); do
    n=$(container exec -u 0 "$cont" sh -c "awk '\$3 ~ /^fuse/' /proc/mounts | wc -l" 2>/dev/null || echo 0)
    [ "$n" -ge 2 ] && break
    sleep 0.2
done
[ "$n" -ge 2 ] || fail "expected 2 fuse mounts ($ws_a + $ws_b), got $n"

# Each marker visible through its OWN workspace.
got_a=$(container exec -u coder --workdir "$ws_a" "$cont" cat marker.txt 2>&1)
assert_eq "$got_a" "from-a" "ws_a marker visible through workspace A"
got_b=$(container exec -u coder --workdir "$ws_b" "$cont" cat marker.txt 2>&1)
assert_eq "$got_b" "from-b" "ws_b marker visible through workspace B"

# Per-workspace shadow stores.
shadow_count=$(container exec -u 0 "$cont" sh -c 'ls /var/lib/rp/shadow 2>/dev/null | wc -l')
[ "$shadow_count" -ge 2 ] || fail "expected >=2 per-workspace shadow subdirs, got $shadow_count"

echo "OK test-multi-mount"
