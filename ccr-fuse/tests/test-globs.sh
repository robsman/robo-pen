#!/bin/sh
# Glob-pattern integration test for ccr-fuse (gitignore semantics).
set -eu

apk add --no-cache fuse3 >/dev/null 2>&1

HOST=/host
SHADOW=/shadow
MNT=/mnt
mkdir -p "$HOST" "$SHADOW" "$MNT"
rm -rf "$HOST"/* "$SHADOW"/* "$HOST"/.[!.]* 2>/dev/null || true

# Fixture: monorepo-like layout
mkdir -p "$HOST/packages/lib-a/src" "$HOST/packages/lib-a/node_modules"
mkdir -p "$HOST/packages/lib-b/node_modules"
mkdir -p "$HOST/services/api/build"
mkdir -p "$HOST/src" "$HOST/scripts"
echo "host-pkg-a" > "$HOST/packages/lib-a/node_modules/pkg-a"
echo "host-pkg-b" > "$HOST/packages/lib-b/node_modules/pkg-b"
echo "src-content" > "$HOST/packages/lib-a/src/main.go"
echo "host-build-1.o" > "$HOST/services/api/build/main.o"
echo "host-build-2.o" > "$HOST/services/api/build/util.o"
echo "real-log" > "$HOST/scripts/deploy.log"
echo "deep-log" > "$HOST/services/api/deploy.log"
echo "src-go" > "$HOST/src/main.go"
echo "root-secret" > "$HOST/secret"
mkdir -p "$HOST/secret-dir-at-root"
echo "ok" > "$HOST/secret-dir-at-root/x"
echo "elsewhere-x" > "$HOST/packages/lib-a/secret-dir-at-root" 2>/dev/null || true

cat > "$HOST/.ccrshadow" <<'EOF'
# gitignore-style patterns
node_modules
*.log
# A slash not at the end anchors the pattern; use leading **/ to match at any depth.
**/build/**/*.o
/secret
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

echo
echo "=== G1: unanchored 'node_modules' matches at any depth ==="
assert_missing "$MNT/packages/lib-a/node_modules"   "G1a packages/lib-a/node_modules hidden"
assert_missing "$MNT/packages/lib-b/node_modules"   "G1b packages/lib-b/node_modules hidden"

echo
echo "=== G2: '*.log' matches at any depth, with various roots ==="
assert_missing "$MNT/scripts/deploy.log"            "G2a scripts/deploy.log hidden"
assert_missing "$MNT/services/api/deploy.log"       "G2b services/api/deploy.log hidden"

echo
echo "=== G3: '**/build/**/*.o' compound nested glob ==="
assert_missing "$MNT/services/api/build/main.o"     "G3a nested build/main.o hidden"
assert_missing "$MNT/services/api/build/util.o"     "G3b nested build/util.o hidden"
# .o outside a build/ dir not matched
echo "not-hidden" > "$HOST/services/api/orphan.o" 2>/dev/null
assert_present "$MNT/services/api/orphan.o"         "G3c .o outside build/ stays visible"

echo
echo "=== G4: anchored '/secret' = root only ==="
assert_missing "$MNT/secret"                        "G4a /secret hidden at root"
# secret-dir-at-root is a different name; shouldn't be hidden
assert_present "$MNT/secret-dir-at-root"            "G4b /secret-dir-at-root visible (different name)"

echo
echo "=== G5: non-rule paths passthrough ==="
assert_present "$MNT/src/main.go"                    "G5a src/main.go visible"
assert_present "$MNT/packages/lib-a/src/main.go"     "G5b packages/lib-a/src visible"

echo
echo "=== G6: container writes to glob-matched paths land in shadow ==="
mkdir -p "$MNT/packages/lib-a/node_modules"
echo "container-pkg-x" > "$MNT/packages/lib-a/node_modules/pkg-x"
assert_eq "$(cat "$MNT/packages/lib-a/node_modules/pkg-x")" "container-pkg-x" "G6a write to nested node_modules"
assert_present "$SHADOW/packages/lib-a/node_modules/pkg-x" "G6b shadow backing has the file"
assert_missing "$HOST/packages/lib-a/node_modules/pkg-x"    "G6c host unchanged"

echo "container.log" > "$MNT/scripts/new.log"
assert_eq "$(cat "$MNT/scripts/new.log")" "container.log" "G6d *.log glob match write"
assert_present "$SHADOW/scripts/new.log"                  "G6e shadow has the .log"
assert_missing "$HOST/scripts/new.log"                     "G6f host unchanged"

echo
echo "=== G7: rm -rf + recreate inside glob-matched dir ==="
rm -rf "$MNT/packages/lib-a/node_modules"
assert_missing "$MNT/packages/lib-a/node_modules"   "G7a removed in container view"
assert_present "$HOST/packages/lib-a/node_modules/pkg-a" "G7b host original survived"
mkdir -p "$MNT/packages/lib-a/node_modules"
for i in $(seq 1 5); do echo "p-$i" > "$MNT/packages/lib-a/node_modules/p-$i"; done
count=$(ls "$MNT/packages/lib-a/node_modules" | wc -l)
assert_eq "$count" "5"                              "G7c 5 fresh files in shadow"

echo
echo "=== G8: host filesystem untouched throughout ==="
assert_eq "$(cat "$HOST/packages/lib-a/node_modules/pkg-a")" "host-pkg-a" "G8a host pkg-a"
assert_eq "$(cat "$HOST/packages/lib-b/node_modules/pkg-b")" "host-pkg-b" "G8b host pkg-b"
assert_eq "$(cat "$HOST/scripts/deploy.log")" "real-log"                   "G8c host *.log untouched"

echo
echo "=== unmount ==="
cd /
fusermount3 -u "$MNT" 2>&1 || umount -l "$MNT"
wait $FPID 2>/dev/null || true

if [ "$FAILED" = "0" ]; then
    echo "ALL GLOB TESTS PASSED"
    exit 0
else
    echo "GLOB TESTS FAILED"
    exit 1
fi
