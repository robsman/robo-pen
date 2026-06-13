#!/bin/sh
# Edge-case integration tests for ccr-fuse.
set -eu

apk add --no-cache fuse3 >/dev/null 2>&1

HOST=/host
SHADOW=/shadow
MNT=/mnt
mkdir -p "$HOST" "$SHADOW" "$MNT"
rm -rf "$HOST"/* "$SHADOW"/* "$HOST"/.[!.]* "$SHADOW"/.[!.]* 2>/dev/null || true

# Fixture
mkdir -p "$HOST/.aws" "$HOST/src" "$HOST/has-symlinks"
echo "real-creds" > "$HOST/.aws/credentials"
echo "real-config" > "$HOST/.aws/config"
ln -s /etc/passwd "$HOST/has-symlinks/danger" 2>/dev/null || true
ln -s "$HOST/.aws/credentials" "$HOST/cred-link" 2>/dev/null || true
# A host file at a rule path that we want hidden — verify it stays hidden via symlink
ln -s nonexistent-target "$HOST/.env.local-link" 2>/dev/null || true

cat > "$HOST/.ccrshadow" <<EOF
.env.local
node_modules
.aws/credentials
build/output
deep/nested/secret
.env.local-link
EOF

/tools/ccr-fuse --backing "$HOST" --shadow "$SHADOW" --mount "$MNT" --rules "$HOST/.ccrshadow" --cache 0.1 &
FPID=$!
for i in 1 2 3 4 5 10; do mountpoint -q "$MNT" && break; sleep 0.2; done
mountpoint -q "$MNT" || { echo FAIL; exit 1; }

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILED=1; }
FAILED=0
assert_missing() { if [ ! -e "$1" ] && [ ! -L "$1" ]; then pass "$2"; else fail "$2 (path $1 exists)"; fi; }
assert_present() { if [ -e "$1" ] || [ -L "$1" ]; then pass "$2"; else fail "$2 (path $1 missing)"; fi; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got=$1 want=$2)"; fi; }

echo "=== T10: rule path with non-existent host parent ==="
# rule "build/output" - host has no "build" dir at all
# ls /workspace should not show "build" (parent dir absent on host)
ls "$MNT" 2>&1 | grep -q "^build$" && fail "T10a build should not appear in root" || pass "T10a build not in root"
# When container creates build/, then writes build/output, it should land in shadow
mkdir "$MNT/build"
assert_present "$MNT/build"                  "T10b after mkdir, build/ exists in mount"
assert_present "$HOST/build"                 "T10c host got build/ (non-rule dir; mkdir propagates)"
echo "secret" > "$MNT/build/output"
assert_eq "$(cat "$MNT/build/output")" "secret" "T10d build/output readable"
assert_missing "$HOST/build/output"          "T10e host build/output stays absent (rule routed to shadow)"
assert_present "$SHADOW/build/output"       "T10f shadow has build/output"

echo
echo "=== T11: deeply nested rule, parents auto-created in shadow ==="
# mkdir of "deep" goes to HOST (not a rule); same for "deep/nested".
# Only "deep/nested/secret" is a rule, routed to shadow.
mkdir -p "$MNT/deep/nested"
echo "deep-secret" > "$MNT/deep/nested/secret"
assert_eq "$(cat "$MNT/deep/nested/secret")" "deep-secret" "T11a deep/nested/secret read back"
assert_missing "$HOST/deep/nested/secret"   "T11b host deep/nested/secret absent"
assert_present "$SHADOW/deep/nested/secret" "T11c shadow deep/nested/secret present"

echo
echo "=== T12: symlinks in passthrough ==="
assert_present "$MNT/cred-link"              "T12a non-rule symlink visible"
# Reading the symlink target points to /host/.aws/credentials which is itself a rule, so reading via the link should... what?
# The symlink target /host/.aws/credentials is an ABSOLUTE path on the host filesystem. Container reads via FUSE goes through /mnt path translation.
# We just check readlink works
target=$(readlink "$MNT/cred-link")
assert_eq "$target" "$HOST/.aws/credentials"  "T12b readlink returns host-path target"
# Reading dangerous symlink: doesn't matter what it does — verify just readlink works
linktarget=$(readlink "$MNT/has-symlinks/danger")
assert_eq "$linktarget" "/etc/passwd"         "T12c absolute symlink target preserved"

echo
echo "=== T13: a host symlink IS a rule (.env.local-link is a symlink, rule applies to it) ==="
assert_missing "$MNT/.env.local-link"        "T13a host symlink hidden by rule"
ln -s /elsewhere "$MNT/.env.local-link"
assert_present "$MNT/.env.local-link"        "T13b container-created symlink visible (shadow)"
new_target=$(readlink "$MNT/.env.local-link")
assert_eq "$new_target" "/elsewhere"          "T13c readlink returns container's target"
# Host original symlink unchanged
host_target=$(readlink "$HOST/.env.local-link")
assert_eq "$host_target" "nonexistent-target" "T13d host symlink untouched"

echo
echo "=== T14: chmod/setattr on shadow file ==="
echo "x" > "$MNT/.env.local"
chmod 600 "$MNT/.env.local"
perm=$(stat -c '%a' "$MNT/.env.local")
assert_eq "$perm" "600"                       "T14a chmod 600 stuck"
chmod 644 "$MNT/.env.local"
perm=$(stat -c '%a' "$MNT/.env.local")
assert_eq "$perm" "644"                       "T14b chmod 644 stuck"

echo
echo "=== T15: open-then-write existing shadow file (Open, not Create) ==="
echo "first" > "$MNT/.env.local"
# Now open existing with > redirection (truncate + write)
echo "second" > "$MNT/.env.local"
assert_eq "$(cat "$MNT/.env.local")" "second" "T15a truncate-write to existing shadow file"
# Append
echo "third" >> "$MNT/.env.local"
content=$(cat "$MNT/.env.local")
expected="second
third"
assert_eq "$content" "$expected"              "T15b append to existing shadow file"

echo
echo "=== T16: large file write/read consistency ==="
dd if=/dev/urandom of=/tmp/blob bs=1M count=8 >/dev/null 2>&1
mkdir -p "$MNT/node_modules"
cp /tmp/blob "$MNT/node_modules/big.bin"
# Verify size and hash
src_size=$(stat -c '%s' /tmp/blob)
dst_size=$(stat -c '%s' "$MNT/node_modules/big.bin")
assert_eq "$dst_size" "$src_size"             "T16a large file size matches"
src_sum=$(sha256sum /tmp/blob | awk "{print \$1}")
dst_sum=$(sha256sum "$MNT/node_modules/big.bin" | awk "{print \$1}")
assert_eq "$dst_sum" "$src_sum"               "T16b large file sha256 matches"
host_path="$HOST/node_modules/big.bin"
assert_missing "$host_path"                   "T16c host never received the blob"

echo
echo "=== T17: concurrent writes don't corrupt rule isolation ==="
(
    for i in $(seq 1 20); do echo "a-$i" > "$MNT/node_modules/file-a-$i"; done
) &
P1=$!
(
    for i in $(seq 1 20); do echo "b-$i" > "$MNT/node_modules/file-b-$i"; done
) &
P2=$!
wait $P1 $P2
count=$(ls "$MNT/node_modules" | grep -c "^file-")
assert_eq "$count" "40"                       "T17a 40 concurrent files in shadow"
# Host should still be empty of these files
host_count=$(ls "$HOST/node_modules" 2>/dev/null | { grep -c "^file-" || true; })
assert_eq "$host_count" "0"                   "T17b host has no concurrent writes"

echo
echo "=== T18: ls inside non-rule subdir with rule sibling absent ==="
ls "$MNT/.aws" | sort > /tmp/aws-listing
expected="config"
# .aws/credentials is rule → hidden unless shadow has it
got=$(cat /tmp/aws-listing | tr "\n" " " | sed "s/ $//")
assert_eq "$got" "$expected"                  "T18a .aws shows only non-rule entries"
# Add shadow content
echo "x" > "$MNT/.aws/credentials"
sleep 0.2
ls "$MNT/.aws" | sort > /tmp/aws-listing2
got2=$(cat /tmp/aws-listing2 | tr "\n" " " | sed "s/ $//")
assert_eq "$got2" "config credentials"        "T18b .aws shows credentials once shadow populated"

echo
echo "=== T19: rmdir empty vs non-empty ==="
mkdir -p "$MNT/node_modules/emptydir"
rmdir "$MNT/node_modules/emptydir"
assert_missing "$MNT/node_modules/emptydir"   "T19a rmdir empty"
mkdir -p "$MNT/node_modules/fulldir"
touch "$MNT/node_modules/fulldir/file"
rmdir "$MNT/node_modules/fulldir" 2>&1 | grep -q "not empty\|Directory not empty\|ENOTEMPTY" && pass "T19b rmdir non-empty fails" || fail "T19b rmdir non-empty should fail"

echo
echo "=== T20: statfs works ==="
df "$MNT" >/dev/null 2>&1 && pass "T20a df succeeds" || fail "T20a df failed"

echo
echo "=== unmount ==="
cd /
fusermount3 -u "$MNT" 2>&1 || umount -l "$MNT"
wait $FPID 2>/dev/null || true

if [ "$FAILED" = "0" ]; then
    echo "ALL EDGE TESTS PASSED"
    exit 0
else
    echo "EDGE TESTS FAILED"
    exit 1
fi
