#!/usr/bin/env bash
# /usr/local/bin/ccr-init.sh
#
# Runs as PID 1 (root, CAP_SYS_ADMIN) at container start.
# Launches ccr-fuse to shadow-mount the host workspace bind onto /workspace.
#
# Layout:
#   /workspace-real           bind from host (where ccr-fuse reads passthrough paths)
#   /var/lib/ccr/shadow       container-local writable store for paths in .ccrshadow
#   /workspace                FUSE mount that user/Claude sees
#
# .ccrshadow (in /workspace-real, one pattern per line):
#   - Matched paths : host content invisible; container's reads/writes go to shadow
#   - Unmatched     : passthrough to host
#
# The container exits if ccr-fuse exits (so failures are visible).
set +e

REAL=/workspace-real
MNT=/workspace
SHADOW=/var/lib/ccr/shadow
RULES="$REAL/.ccrshadow"

if [ ! -d "$REAL" ]; then
    echo "ccr-init: $REAL does not exist; nothing to mount" >&2
    exec sleep infinity
fi

mkdir -p "$MNT" "$SHADOW"

# If already mounted (e.g., container restart with stale state), unmount first.
if mountpoint -q "$MNT"; then
    fusermount3 -u "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
fi

RULES_FLAG=""
if [ -f "$RULES" ]; then
    RULES_FLAG="--rules $RULES"
    echo "ccr-init: using rules from $RULES" >&2
else
    echo "ccr-init: no .ccrshadow in workspace; pure passthrough" >&2
fi

# Launch ccr-fuse in the foreground so the container exits if it dies.
echo "ccr-init: launching ccr-fuse" >&2
exec /usr/local/bin/ccr-fuse \
    --backing "$REAL" \
    --shadow "$SHADOW" \
    --mount "$MNT" \
    $RULES_FLAG
