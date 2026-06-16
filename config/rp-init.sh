#!/usr/bin/env bash
# /usr/local/bin/rp-init.sh
#
# Runs as PID 1 (root, CAP_SYS_ADMIN) at container start.
# Sets up the shadow boundary then launches rp-fuse.
#
# Boundary setup:
#   1. Move the host bind from /workspace-real to /var/lib/rp/backing
#      (root-only, mode 0700 — invisible to coder).
#   2. Overlay a tmpfs on /workspace-real so any container process looking at
#      that path sees an empty filesystem instead of host content.
#
# Layout after init:
#   /workspace-real           tmpfs overlay (empty, hiding the original bind)
#   /var/lib/rp/backing      bind to the host workspace (root-only)
#   /var/lib/rp/shadow       container-local writable store for shadowed paths
#   /workspace                FUSE mount that user/Claude sees
#
# Why this matters: see docs/adr/0005-shadow-as-security-boundary-via-drop-sudo.md.
# coder has no sudo and no capabilities, so it cannot umount the tmpfs or
# traverse /var/lib/rp to reach the host content directly.
#
# The container exits if rp-fuse exits.
set +e

REAL=/workspace-real
MNT=/workspace
BACKING=/var/lib/rp/backing
SHADOW=/var/lib/rp/shadow
RULES="$BACKING/.rp/shadow"

if [ ! -d "$REAL" ]; then
    echo "rp-init: $REAL does not exist; nothing to mount" >&2
    exec sleep infinity
fi

mkdir -p "$MNT" "$BACKING" "$SHADOW"
chmod 0700 /var/lib/rp

# Re-assert the shadow-boundary invariants (ADR-0005 / ADR-0008 invariant 3):
# the configured container user must exist, have uid != 0, and not be listed
# in any sudoers file. The overlay build enforces the same checks; this is
# belt-and-braces against (a) a build path that slips a privileged user
# through, (b) a sudoers edit that landed between build and start.
if [ -n "${RP_USER:-}" ]; then
    if ! id -u "$RP_USER" >/dev/null 2>&1; then
        echo "rp-init: configured RP_USER '$RP_USER' does not exist in image; refusing to launch" >&2
        exec sleep infinity
    fi
    if [ "$(id -u "$RP_USER")" = "0" ]; then
        echo "rp-init: configured RP_USER '$RP_USER' has uid 0; refusing to launch (shadow boundary requires uid != 0)" >&2
        exec sleep infinity
    fi
    # Strip comments before matching so a legitimate base-image comment
    # like '# Ditto for GPG agent' doesn't false-positive when the
    # configured user happens to be named the same as a word in comments.
    if cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null | sed 's/#.*//' \
            | grep -qE "(^|[[:space:]])${RP_USER}([[:space:]]|$)"; then
        echo "rp-init: configured RP_USER '$RP_USER' has a sudoers entry; refusing to launch (shadow boundary requires no sudo)" >&2
        exec sleep infinity
    fi
fi

# If a prior init left an FUSE mount around, drop it.
if mountpoint -q "$MNT"; then
    fusermount3 -u "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
fi

# Move the host bind to /var/lib/rp/backing (where rp-fuse will read it from)
# unless it already moved (e.g. container restart inside the same mount ns).
if ! mountpoint -q "$BACKING"; then
    mount --bind "$REAL" "$BACKING" || {
        echo "rp-init: FAILED to bind $REAL -> $BACKING" >&2
        exec sleep infinity
    }
    echo "rp-init: bound $REAL -> $BACKING" >&2
fi

# Hide /workspace-real from the container namespace. Any process (including
# coder, but it has no caps anyway) sees an empty tmpfs at that path.
if ! grep -qE " $REAL tmpfs " /proc/mounts; then
    mount -t tmpfs -o mode=755,uid=0,gid=0 none "$REAL" || {
        echo "rp-init: FAILED to overlay tmpfs on $REAL" >&2
        exec sleep infinity
    }
    echo "rp-init: hid $REAL with tmpfs" >&2
fi

RULES_FLAG=""
if [ -f "$RULES" ]; then
    RULES_FLAG="--rules $RULES"
    echo "rp-init: using rules from $RULES" >&2
else
    echo "rp-init: no .rp/shadow in workspace; pure passthrough" >&2
fi

CACHE_FLAG=""
if [ -n "${RP_CACHE:-}" ]; then
    CACHE_FLAG="--cache $RP_CACHE"
    echo "rp-init: fuse cache TTL = ${RP_CACHE}s (from RP_CACHE)" >&2
fi

DEBUG_FLAG=""
if [ "${RP_DEBUG:-}" = "1" ]; then
    DEBUG_FLAG="--debug"
    echo "rp-init: FUSE debug logging enabled (RP_DEBUG=1)" >&2
fi

echo "rp-init: launching rp-fuse" >&2
exec /usr/local/bin/rp-fuse \
    --backing "$BACKING" \
    --shadow "$SHADOW" \
    --mount "$MNT" \
    $RULES_FLAG \
    $CACHE_FLAG \
    $DEBUG_FLAG
