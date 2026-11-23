#!/usr/bin/env bash
# ADR-0022 + ADR-0023: content-addressed images, config.local.yaml fallback.
#
# Property: two worktrees of one repo share one image (the second create
# builds nothing), both pick up the repo home's config.local.yaml, a change
# to an image input is reported on the next start, `rp recreate` rebuilds
# under the same name, and `rp destroy` leaves the shared image alone.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

base=$(mk_probe image-reuse)
g init -q "$base/rpimg"
(cd "$base/rpimg" && "$RP" init >/dev/null)
g -C "$base/rpimg" add -A
g -C "$base/rpimg" commit -q -m init
g -C "$base/rpimg" worktree add -q -b a "$base/rpimg-a"
g -C "$base/rpimg" worktree add -q -b b "$base/rpimg-b"

# Personal config only in the repo home; a host_files entry makes the
# fallback observable inside the worktree containers.
echo "from-repo-home" > "$base/marker"
cat > "$base/rpimg/.rp/config.local.yaml" <<EOF
host_files:
  - src: $base/marker
    dst: /home/{{user}}/rp-fallback-marker
EOF

ca=$(container_name claude-code rpimg-a)
cb=$(container_name claude-code rpimg-b)
remember_container "$ca"
remember_container "$cb"
image_of() { container inspect "$1" | jq -r '.[0].configuration.image.reference'; }
label_of() { container inspect "$1" | jq -r ".[0].configuration.labels[\"$2\"] // empty"; }

cd "$base/rpimg-a"
out=$("$RP" create 2>&1) || fail "rp create in rpimg-a failed: $out"
assert_contains "$out" "building overlay -> rp-img-claude-code-" "first worktree builds"

cd "$base/rpimg-b"
out=$("$RP" create 2>&1) || fail "rp create in rpimg-b failed: $out"
assert_contains "$out" "reusing rp-img-claude-code-" "second worktree reuses the image"
assert_eq "$(image_of "$cb")" "$(image_of "$ca")" "both worktrees run the same image"
assert_eq "$(label_of "$cb" rp.image_hash)" "$(label_of "$ca" rp.image_hash)" "same image hash label"

out=$(container exec -u coder "$cb" cat /home/coder/rp-fallback-marker 2>&1)
assert_eq "$out" "from-repo-home" "repo home config.local.yaml applies to the worktree"

# An image input changes on the host (as after a branch switch).
echo "extra instructions" > "$base/rpimg-b/.rp/instructions.md"
out=$("$RP" _ensure 2>&1) || fail "rp _ensure failed: $out"
assert_contains "$out" "image inputs of $cb changed" "staleness warning"

old_image=$(image_of "$cb")
out=$("$RP" recreate 2>&1) || fail "rp recreate failed: $out"
container inspect "$cb" >/dev/null 2>&1 || fail "recreate did not keep the name $cb"
[ "$(image_of "$cb")" != "$old_image" ] || fail "recreate kept the old image"
out=$("$RP" _ensure 2>&1) || fail "rp _ensure after recreate failed: $out"
case "$out" in *"changed since it was created"*) fail "still stale after recreate: $out" ;; esac

# destroy keeps images: they are shared and removed only by rp gc.
a_image=$(image_of "$ca")
cd "$base/rpimg-a"
"$RP" destroy >/dev/null 2>&1 || fail "rp destroy failed"
container image inspect "$a_image" >/dev/null 2>&1 || fail "destroy removed the shared image $a_image"

echo "OK test-image-reuse"
