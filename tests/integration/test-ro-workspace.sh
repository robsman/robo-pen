#!/usr/bin/env bash
# Property: `rp create --name N path:ro` mounts that workspace read-only.
# Writes return EROFS at the kernel level; the agent sees "Read-only file
# system".
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe rows)
cd "$ws"
"$RP" init >/dev/null

cont=$(container_name claude-code rows)
container delete --force "$cont" >/dev/null 2>&1 || true
remember_container "$cont"

"$RP" create --name rows "$ws:ro" >/dev/null 2>&1 \
    || fail "rp create --name rows $ws:ro failed"
container start "$cont" >/dev/null 2>&1 || fail "container start $cont failed"

# Wait for the fuse mount.
for _ in $(seq 1 30); do
    container exec -u 0 "$cont" awk -v m="$ws" '$2==m && $3 ~ /^fuse/' /proc/mounts 2>/dev/null | grep -q . && break
    sleep 0.2
done

# Fuse mount-line options (field 4) include "ro".
line=$(container exec -u 0 "$cont" awk -v m="$ws" '$2==m && $3 ~ /^fuse/' /proc/mounts 2>&1)
opts=$(awk '{print $4}' <<<"$line")
echo ",$opts," | grep -q ',ro,' || fail "fuse mount not flagged ro: $line"

# Writing fails.
out=$(container exec -u coder --workdir "$ws" "$cont" sh -c 'touch newfile.txt 2>&1; echo EXIT=$?' 2>&1)
echo "$out" | grep -q 'EXIT=0' && fail "expected touch to fail on ro mount: $out"
echo "$out" | grep -qi 'read[ -]only\|EROFS' || fail "expected read-only error: $out"

# Reading still works.
reads=$(container exec -u coder --workdir "$ws" "$cont" ls -A 2>&1)
echo "$reads" | grep -q '\.rp' || fail "expected .rp/ visible on ro mount: $reads"

echo "OK test-ro-workspace"
