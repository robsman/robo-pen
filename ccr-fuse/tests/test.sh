#!/bin/sh
# Functional test for rule-aware ccr-fuse.
set -eu

apk add --no-cache fuse3 >/dev/null 2>&1

HOST=/host
SHADOW=/shadow
MNT=/mnt
mkdir -p "$HOST" "$SHADOW" "$MNT"

# Set up host fixture
rm -rf "$HOST"/* "$SHADOW"/* 2>/dev/null || true
echo "real-secret" > "$HOST/.env.local"
mkdir -p "$HOST/src"
echo "source content" > "$HOST/src/main.go"
mkdir -p "$HOST/.aws"
echo "real-credentials" > "$HOST/.aws/credentials"
echo "real-config" > "$HOST/.aws/config"
# pre-populate a host node_modules to ensure we DO NOT see it
mkdir -p "$HOST/node_modules"
echo "real-pkg" > "$HOST/node_modules/pre-existing"

# Rules file
cat > "$HOST/.ccrshadow" <<EOF
.env.local
node_modules
.aws/credentials
EOF

echo "=== host fixture ==="
find "$HOST" -type f -o -type d | sort
echo

# Launch
/tools/ccr-fuse --backing "$HOST" --shadow "$SHADOW" --mount "$MNT" --rules "$HOST/.ccrshadow" &
FPID=$!
for i in 1 2 3 4 5 10; do mountpoint -q "$MNT" && break; sleep 0.2; done
mountpoint -q "$MNT" || { echo FAIL; exit 1; }
echo "mounted"
echo

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILED=1; }
FAILED=0

assert_missing() {
    if [ ! -e "$1" ]; then pass "$2 missing as expected"; else fail "$2 unexpectedly present: $1"; fi
}
assert_present() {
    if [ -e "$1" ]; then pass "$2 present"; else fail "$2 missing: $1"; fi
}
assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got $1, want $2)"; fi
}

echo "=== T1: rule-matched host content invisible ==="
assert_missing "$MNT/.env.local"          "T1a /.env.local"
assert_missing "$MNT/node_modules"        "T1b /node_modules (host pre-existing hidden)"
assert_missing "$MNT/.aws/credentials"    "T1c /.aws/credentials"

echo
echo "=== T2: non-rule passthrough still works ==="
assert_present "$MNT/src/main.go"          "T2a /src/main.go"
assert_eq "$(cat "$MNT/src/main.go")" "source content" "T2b /src/main.go content"
assert_present "$MNT/.aws/config"          "T2c /.aws/config (non-masked sibling)"
assert_eq "$(cat "$MNT/.aws/config")" "real-config" "T2d /.aws/config content"

echo
echo "=== T3: container writes to ignored paths go to shadow only ==="
echo "container-secret" > "$MNT/.env.local"
mkdir -p "$MNT/node_modules"
echo "pkg-x" > "$MNT/node_modules/pkg-x"
mkdir -p "$MNT/node_modules/sub"
echo "deep" > "$MNT/node_modules/sub/deep.txt"
echo "container-creds" > "$MNT/.aws/credentials"

assert_eq "$(cat "$MNT/.env.local")"          "container-secret"  "T3a read back container-written /.env.local"
assert_eq "$(cat "$MNT/.aws/credentials")"    "container-creds"   "T3b read back container-written /.aws/credentials"
assert_eq "$(cat "$MNT/node_modules/pkg-x")"  "pkg-x"             "T3c read back /node_modules/pkg-x"
assert_eq "$(cat "$MNT/node_modules/sub/deep.txt")" "deep"        "T3d nested /node_modules/sub/deep.txt"

echo
echo "=== T4: host filesystem untouched ==="
assert_eq "$(cat "$HOST/.env.local")"        "real-secret"       "T4a host .env.local unchanged"
assert_eq "$(cat "$HOST/.aws/credentials")"  "real-credentials"  "T4b host .aws/credentials unchanged"
assert_eq "$(cat "$HOST/node_modules/pre-existing")" "real-pkg"  "T4c host node_modules/pre-existing unchanged"
assert_missing "$HOST/node_modules/pkg-x"     "T4d host has no container's pkg-x"
assert_missing "$HOST/node_modules/sub"       "T4e host has no /sub dir"

echo
echo "=== T5: shadow backing store has expected layout ==="
assert_present "$SHADOW/.env.local"          "T5a shadow /.env.local"
assert_present "$SHADOW/node_modules"        "T5b shadow /node_modules dir"
assert_present "$SHADOW/node_modules/pkg-x"  "T5c shadow /node_modules/pkg-x"
assert_present "$SHADOW/.aws/credentials"    "T5d shadow /.aws/credentials"

echo
echo "=== T6: rm -rf then recreate (build-script scenario) ==="
rm -rf "$MNT/node_modules"
assert_missing "$MNT/node_modules"            "T6a /node_modules removed in container view"
assert_present "$HOST/node_modules/pre-existing" "T6b host node_modules survived"
mkdir -p "$MNT/node_modules"
for i in $(seq 1 50); do echo "pkg-$i" > "$MNT/node_modules/p-$i"; done
count=$(ls "$MNT/node_modules" | wc -l)
assert_eq "$count" "50"                       "T6c 50 fresh files in /node_modules"
assert_missing "$HOST/node_modules/p-1"       "T6d host still untouched after recreate"

echo
echo "=== T7: ls /workspace doesn't show masked entries until container creates them ==="
# Wipe shadow's .env.local; should disappear from listing
rm -f "$MNT/.env.local"
sleep 1.2  # outlast cache TTL
listing=$(ls -a "$MNT" | grep -E "^\.env\.local$" || true)
assert_eq "$listing" ""                        "T7a /.env.local gone from listing after unlink"

echo
echo "=== T8: source edit on non-rule path propagates to host ==="
echo "edited-in-container" > "$MNT/src/main.go"
assert_eq "$(cat "$HOST/src/main.go")" "edited-in-container" "T8 host saw container's edit"

echo
echo "=== T9: rename within shadow ==="
mv "$MNT/node_modules/p-1" "$MNT/node_modules/p-1-renamed" 2>&1
assert_present "$MNT/node_modules/p-1-renamed" "T9a renamed file present"
assert_missing "$MNT/node_modules/p-1"        "T9b old name gone"

echo
echo "=== unmount ==="
cd /
fusermount3 -u "$MNT" || umount -l "$MNT"
wait $FPID 2>/dev/null || true

echo
if [ "$FAILED" = "0" ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "TESTS FAILED"
    exit 1
fi
