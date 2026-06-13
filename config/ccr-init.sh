#!/usr/bin/env bash
# /usr/local/bin/ccr-init.sh
#
# Runs as PID 1 (root, CAP_SYS_ADMIN) at container start.
# Sets up the shadow boundary then launches ccr-fuse.
#
# Boundary setup:
#   1. Move the host bind from /workspace-real to /var/lib/ccr/backing
#      (root-only, mode 0700 — invisible to coder).
#   2. Overlay a tmpfs on /workspace-real so any container process looking at
#      that path sees an empty filesystem instead of host content.
#
# Layout after init:
#   /workspace-real           tmpfs overlay (empty, hiding the original bind)
#   /var/lib/ccr/backing      bind to the host workspace (root-only)
#   /var/lib/ccr/shadow       container-local writable store for shadowed paths
#   /workspace                FUSE mount that user/Claude sees
#
# Why this matters: see docs/adr/0005-shadow-as-security-boundary-via-drop-sudo.md.
# coder has no sudo and no capabilities, so it cannot umount the tmpfs or
# traverse /var/lib/ccr to reach the host content directly.
#
# The container exits if ccr-fuse exits.
set +e

REAL=/workspace-real
MNT=/workspace
BACKING=/var/lib/ccr/backing
SHADOW=/var/lib/ccr/shadow
RULES="$BACKING/.ccrshadow"

if [ ! -d "$REAL" ]; then
    echo "ccr-init: $REAL does not exist; nothing to mount" >&2
    exec sleep infinity
fi

mkdir -p "$MNT" "$BACKING" "$SHADOW"
chmod 0700 /var/lib/ccr

# If a prior init left an FUSE mount around, drop it.
if mountpoint -q "$MNT"; then
    fusermount3 -u "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
fi

# Move the host bind to /var/lib/ccr/backing (where ccr-fuse will read it from)
# unless it already moved (e.g. container restart inside the same mount ns).
if ! mountpoint -q "$BACKING"; then
    mount --bind "$REAL" "$BACKING" || {
        echo "ccr-init: FAILED to bind $REAL -> $BACKING" >&2
        exec sleep infinity
    }
    echo "ccr-init: bound $REAL -> $BACKING" >&2
fi

# Hide /workspace-real from the container namespace. Any process (including
# coder, but it has no caps anyway) sees an empty tmpfs at that path.
if ! grep -qE " $REAL tmpfs " /proc/mounts; then
    mount -t tmpfs -o mode=755,uid=0,gid=0 none "$REAL" || {
        echo "ccr-init: FAILED to overlay tmpfs on $REAL" >&2
        exec sleep infinity
    }
    echo "ccr-init: hid $REAL with tmpfs" >&2
fi

RULES_FLAG=""
if [ -f "$RULES" ]; then
    RULES_FLAG="--rules $RULES"
    echo "ccr-init: using rules from $RULES" >&2
else
    echo "ccr-init: no .ccrshadow in workspace; pure passthrough" >&2
fi

echo "ccr-init: launching ccr-fuse" >&2
exec /usr/local/bin/ccr-fuse \
    --backing "$BACKING" \
    --shadow "$SHADOW" \
    --mount "$MNT" \
    $RULES_FLAG
