#!/bin/bash -p
# /usr/local/bin/rp-init.sh
#
# Note the shebang: `bash -p`. By default bash auto-resets EUID to RUID at
# startup as a security measure when invoked with mismatched IDs. That kills
# the escalation done by /usr/local/bin/rp-init-bootstrap (setuid root) when
# we land in containers whose default user is non-root. The -p flag
# preserves the setuid escalation so the script runs as root regardless of
# the runtime's default-user policy.
#
# Runs as PID 1 (root, CAP_SYS_ADMIN) at container start.
# Sets up the shadow boundary for one or more workspaces, then launches
# rp-fuse with --workspace flags for each.
#
# Mount layout PER workspace:
#   1. Unwind any prior stacked mounts so we rebuild from a known state.
#   2. Capture an fd on the bind BEFORE any overmount. The kernel resolves
#      /proc/self/fd/N through the inode the fd already opens, so rp-fuse
#      reaches the original host bind via /proc/self/fd/N regardless of
#      whatever sits on top of the workspace path later.
#   3. Mount tmpfs on the workspace path — fail-closed backstop.
#
# Then rp-fuse is exec'd ONCE with multiple --workspace flags. It mounts a
# FUSE tree per workspace, holding all fds open. If any FUSE server exits,
# the others are unmounted and the process exits (matches container-level
# fail-closed: rp-fuse death = tini exit = container death).
#
# Failure semantics:
#   * Pre-tmpfs failures for any workspace (mkdir of shadow store, unwind,
#     fd capture, tmpfs itself) exit non-zero. Container dies rather than
#     sleep with a raw bind exposed.
#   * Post-tmpfs failures (user validation, rp-fuse exec) use `sleep
#     infinity` so the operator can `<runtime> exec` to debug. tmpfs hides
#     each workspace bind for the duration of that sleep.
#
# Why this matters: see docs/adr/0005-shadow-as-security-boundary-via-drop-sudo.md
# and docs/adr/0010-setuid-init-bootstrap.md.
#
# The container exits if rp-fuse exits.
set +e

SHADOW=/var/lib/rp/shadow

# Diagnostic mode. RP_DIAGNOSE=1 turns pre-tmpfs failures into `sleep
# infinity` (with full state dumped to the log) instead of `exit 1`. Use
# when the runtime swallows stdout/stderr (e.g. Docker Sandbox) and you
# need to `<runtime> exec` into the still-alive container to read the log.
# DO NOT leave this on in production — `sleep infinity` with the raw bind
# exposed is fail-open.
#
# Log location: $RP_LOG_DIR/rp-init.log if RP_LOG_DIR is set + writable,
# else /tmp/rp-init.log (container-local, dies with container).
if [ -n "${RP_LOG_DIR:-}" ] && [ -d "$RP_LOG_DIR" ] && [ -w "$RP_LOG_DIR" ]; then
    DIAG_LOG="$RP_LOG_DIR/rp-init.log"
else
    DIAG_LOG=/tmp/rp-init.log
fi
# Heartbeat write so users diagnosing Sandbox-like environments can confirm
# the script even started.
{
    echo "=== rp-init started $(date -Iseconds 2>/dev/null || date) ==="
    echo "rp-init: pid=$$ ppid=$PPID uid=$(id -u) euid=$(id -u 2>/dev/null) DIAG=${RP_DIAGNOSE:-0} LOG_DIR=${RP_LOG_DIR:-}"
} > "$DIAG_LOG" 2>/dev/null || true

diag_init() {
    : > "$DIAG_LOG"
    {
        echo "=== rp-init diagnostic dump ($(date -Iseconds 2>/dev/null || date)) ==="
        echo
        echo "--- /proc/1/status (Uid/Gid/Caps) ---"
        grep -E '^(Uid|Gid|CapInh|CapPrm|CapEff|CapBnd|CapAmb):' /proc/1/status
        echo
        echo "--- env (rp-relevant) ---"
        env | grep -E '^(RP_|HOME|PATH|USER|UID|GID)' | sort
        echo
        echo "--- /proc/mounts ---"
        cat /proc/mounts
        echo
    } >> "$DIAG_LOG" 2>&1
}

die() {
    local reason=$1
    echo "rp-init: FAILED ($reason)" >&2
    if [ "${RP_DIAGNOSE:-}" = "1" ]; then
        diag_init
        {
            echo "--- failure ---"
            echo "$reason"
        } >> "$DIAG_LOG"
        echo "rp-init: diagnostic dumped to $DIAG_LOG; sleeping for inspection (RP_DIAGNOSE=1)" >&2
        exec sleep infinity
    fi
    exit 1
}

# --- Workspace discovery -------------------------------------------------
#
# Two sources, evaluated in order:
#   1. $RP_WORKSPACE if set — space-separated list of `path[:ro]` entries.
#      Each path must be a directory containing `.rp/`. The rp wrapper
#      sets this to the host path of each bound workspace (1:1 bind, so
#      the same path inside and outside the container).
#   2. Scan /proc/mounts for virtiofs / 9p / fakeowner mounts whose target
#      is a directory containing .rp/. Every matching mount becomes a
#      workspace (multi-mount support). Fallback for runtimes that don't
#      pass RP_WORKSPACE.
#
# Emits one `path[:ro]` entry per line on stdout. Empty stdout = none found.

discover_workspaces() {
    if [ -n "${RP_WORKSPACE:-}" ]; then
        local entry p ro
        local any=0
        for entry in $RP_WORKSPACE; do
            ro=""
            p=$entry
            case "$entry" in
                *:ro) p=${entry%:ro}; ro=":ro" ;;
            esac
            # rp lists its workspaces explicitly, so no .rp/ marker is
            # needed: a worktree of a repo that doesn't commit .rp/ takes
            # the repo home's rules (RP_SHADOW_FALLBACK), anything else
            # runs with an empty rule set (ADR-0023).
            if [ -d "$p" ]; then
                echo "$p$ro"
                any=1
            else
                echo "rp-init: WARN RP_WORKSPACE entry '$p' does not exist, skipping" >&2
            fi
        done
        [ "$any" -eq 1 ] && return 0
        return 1
    fi
    # Scan host-share fstypes for .rp/-marked directories.
    local any=0
    while read -r _ target fstype _; do
        case "$fstype" in virtiofs|9p|fakeowner|fuse.fakeowner) ;; *) continue ;; esac
        [ -d "$target" ] || continue
        [ -d "$target/.rp" ] || continue
        echo "$target"
        any=1
    done < /proc/mounts
    [ "$any" -eq 1 ] && return 0
    return 1
}

# Parse a `path[:ro]` entry into globals ENTRY_PATH and ENTRY_RO_SUFFIX.
parse_entry() {
    ENTRY_RO_SUFFIX=""
    ENTRY_PATH=$1
    case "$1" in
        *:ro) ENTRY_PATH=${1%:ro}; ENTRY_RO_SUFFIX=":ro" ;;
    esac
}

# Count /proc/mounts lines targeting $1.
mount_count() { awk -v m="$1" '$2==m' /proc/mounts | wc -l; }

# Unwind any stacked mounts on $1 (FUSE, tmpfs) leaving the runtime bind in
# place. The bind is the bottom of the stack (exactly one /proc/mounts
# line targets $1 once unwound).
unwind_stack() {
    local target=$1 attempts=0
    while [ "$(mount_count "$target")" -gt 1 ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -le 8 ] || die "$target still has stacked mounts after 8 umount attempts"
        fusermount3 -u "$target" 2>/dev/null \
            || umount "$target" 2>/dev/null \
            || umount -l "$target" 2>/dev/null \
            || die "cannot unwind stacked mount on $target"
    done
}

# Allocate a free fd and open it (read-only) on $1. Stores the fd number
# in the global ALLOCATED_FD on success.
#
# We use bash's `exec {var}<file` syntax (kernel picks the fd, bash clears
# close-on-exec correctly so the fd survives the later exec into rp-fuse).
# Explicit numeric fds via `exec 10<file` are subject to bash's internal
# 10+ range and don't reliably survive exec.
#
# Caveat: `{var}<file` needs `var` to be a literal token at parse time.
# We synthesise the var name (FD_0, FD_1, …) inside an eval. The caller
# passes a unique slot via the $2 argument.
ALLOCATED_FD=
allocate_fd_on() {
    local file=$1 slot=$2 var="FD_$slot"
    eval "exec {$var}<\"\$file\"" || return 1
    ALLOCATED_FD=${!var}
}

# --- Discover -----------------------------------------------------------

mapfile -t WORKSPACES < <(discover_workspaces)
[ "${#WORKSPACES[@]}" -gt 0 ] \
    || die "no rp workspace found; set RP_WORKSPACE or bind a workspace dir whose root has .rp/ (virtiofs/9p/fakeowner mount)"

echo "rp-init: workspaces:" >&2
for entry in "${WORKSPACES[@]}"; do
    echo "  $entry" >&2
done

# --- Pre-cover phase: failures here exit. -------------------------------

mkdir -p "$SHADOW" || die "cannot mkdir $SHADOW"
chmod 0700 /var/lib/rp

# Some Sandbox-style base images (notably docker/sandbox-templates:shell-docker)
# ship without /dev/fuse but grant CAP_MKNOD. The kernel fuse driver
# auto-loads on first open of the device, so creating it on demand is safe.
if [ ! -e /dev/fuse ]; then
    if mknod /dev/fuse c 10 229 2>/dev/null && chmod 0666 /dev/fuse 2>/dev/null; then
        echo "rp-init: created missing /dev/fuse (c 10 229)" >&2
    else
        echo "rp-init: WARN /dev/fuse missing and could not be created" >&2
    fi
fi

# Host aliases — append /etc/hosts entries so the container user can
# resolve well-known names (host.containers.internal, user-supplied
# aliases from .rp/config.yaml). Apple Container has no --add-host
# equivalent, so we do this from PID 1 where we still have root +
# can edit /etc/hosts. RP_HOST_ALIASES is comma-separated `name=ip`
# pairs; the literal "host-gateway" resolves to the container's default
# gateway (which is the host on virtio/fakeowner setups).
if [ -n "${RP_HOST_ALIASES:-}" ]; then
    # Read the default gateway from /proc/net/route. Lines are tab-separated:
    #   Iface  Destination  Gateway  Flags  …
    # `00000000` in column 2 = the default route. Column 3 is the gateway
    # IPv4 as 8 hex chars in little-endian byte order. We avoid the `ip`
    # tool (iproute2) and gawk-only functions (strtonum) so we don't
    # depend on either being installed in the user's image.
    #
    # The default route appears asynchronously: Apple Container brings
    # the network up after PID 1 starts running. Poll for up to ~3s so
    # `host-gateway` aliases resolve on first boot too (subsequent
    # restarts find it immediately).
    read_gateway() {
        local hex=""
        while IFS=$'\t ' read -r _ dest gw _; do
            if [ "$dest" = "00000000" ]; then
                hex=$gw
                break
            fi
        done < <(tail -n +2 /proc/net/route 2>/dev/null)
        [ -z "$hex" ] && return 1
        # Hex is BE-printed little-endian bytes: "0140A8C0" → bytes 01 40 A8 C0
        # → IPv4 192.168.64.1.
        printf '%d.%d.%d.%d' \
            "$((16#${hex:6:2}))" \
            "$((16#${hex:4:2}))" \
            "$((16#${hex:2:2}))" \
            "$((16#${hex:0:2}))"
    }
    gateway=""
    # 30 × 0.1s = ~3s ceiling; in practice the route appears within ~200ms.
    for _ in $(seq 1 30); do
        if g=$(read_gateway); then
            gateway=$g
            break
        fi
        sleep 0.1
    done
    # Strip any prior rp-managed entries so re-launches stay idempotent.
    if [ -w /etc/hosts ]; then
        sed -i '/# rp-host-alias$/d' /etc/hosts 2>/dev/null || true
        IFS=',' read -ra aliases <<<"$RP_HOST_ALIASES"
        for entry in "${aliases[@]}"; do
            name=${entry%%=*}
            ip=${entry#*=}
            if [ "$ip" = "host-gateway" ]; then
                if [ -z "$gateway" ]; then
                    echo "rp-init: WARN no default route, skipping alias $name=host-gateway" >&2
                    continue
                fi
                ip=$gateway
            fi
            echo "$ip $name # rp-host-alias" >> /etc/hosts
            echo "rp-init: /etc/hosts $name -> $ip" >&2
        done
    else
        echo "rp-init: WARN /etc/hosts not writable; host aliases dropped" >&2
    fi
fi

# Per mount: unwind → capture fd → tmpfs cover. Build the rp-fuse argv
# along the way (one `--workspace path=fd[:ro]` per entry).
FUSE_ARGS=()
slot=0
cover_and_register() {
    local p=$1 ro=$2 fd

    [ -d "$p" ] || die "$p does not exist"

    unwind_stack "$p"

    allocate_fd_on "$p" "$slot" || die "fd capture failed for $p"
    fd=$ALLOCATED_FD
    echo "rp-init: opened backing fd $fd on $p" >&2

    mount -t tmpfs -o mode=755,uid=0,gid=0 none "$p" \
        || die "FAILED to overlay tmpfs on $p"
    echo "rp-init: overlaid tmpfs on $p" >&2

    FUSE_ARGS+=(--workspace "$p=$fd$ro")
    slot=$((slot + 1))
}

for entry in "${WORKSPACES[@]}"; do
    parse_entry "$entry"
    cover_and_register "$ENTRY_PATH" "$ENTRY_RO_SUFFIX"
done

# Shadow rules captured from the repo home for workspaces without .rp/
# (ADR-0023). Written root-only under /var/lib/rp (0700); rp-fuse uses a
# file only while its workspace has no .rp/.
rules_slot=0
for pair in ${RP_SHADOW_FALLBACK:-}; do
    ws=${pair%%=*}
    mkdir -p /var/lib/rp/rules
    rules_file=/var/lib/rp/rules/$rules_slot
    printf '%s' "${pair#*=}" | base64 -d > "$rules_file" 2>/dev/null \
        || die "cannot decode the fallback shadow rules for $ws"
    FUSE_ARGS+=(--rules "$ws=$rules_file")
    echo "rp-init: shadow rules for $ws from the repo home's .rp/shadow" >&2
    rules_slot=$((rules_slot + 1))
done

# Git stores outside the workspaces, e.g. a worktree's common dir
# (ADR-0019). RP_GIT_DIRS is a space-separated list of `path[:ro]` entries.
# They are not workspaces: no .rp/ is required, and rp-fuse finds no
# .rp/shadow there, so it applies an empty rule set. Read-write entries
# are plain binds and need nothing here. Read-only entries get the same
# cover as workspaces, because only rp-fuse enforces :ro (the runtime's
# -v has no read-only flag).
for entry in ${RP_GIT_DIRS:-}; do
    parse_entry "$entry"
    if [ -z "$ENTRY_RO_SUFFIX" ]; then
        echo "rp-init: git dir $ENTRY_PATH (read-write bind)" >&2
        continue
    fi
    echo "rp-init: git dir $ENTRY_PATH (read-only, via rp-fuse)" >&2
    cover_and_register "$ENTRY_PATH" ":ro"
done

# --- Post-cover phase: failures here sleep (debuggable). ----------------

# Re-assert the shadow-boundary invariants (ADR-0005 / ADR-0008 invariant 3):
# the configured container user must exist, have uid != 0, and not be listed
# in any sudoers file. The overlay build enforces the same checks; this is
# belt-and-braces against build paths that slip a privileged user through,
# or a sudoers edit that landed between build and start.
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
    # Bypass with RP_ALLOW_SUDO=1 (required for Docker Sandbox).
    if [ "${RP_ALLOW_SUDO:-}" != "1" ] \
            && cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null | sed 's/#.*//' \
            | grep -qE "(^|[[:space:]])${RP_USER}([[:space:]]|$)"; then
        echo "rp-init: configured RP_USER '$RP_USER' has a sudoers entry; refusing to launch (shadow boundary requires no sudo; set RP_ALLOW_SUDO=1 to bypass)" >&2
        exec sleep infinity
    fi
fi

# Persistent volumes (ADR-0014). RP_VOLUMES is comma-separated
# `mount=name` pairs (e.g. `/home/coder/.claude=claude-home`). For each:
#   1. chown the mount target to RP_USER (host bind shows up with macOS
#      uids that don't map to anything sensible inside the container).
#   2. If the mount is empty AND the image stashed a seed at
#      /usr/local/share/rp/seed/<name>/, copy the seed into the mount.
#      This is the bootstrap path so default profile-provided files
#      (settings.json, CLAUDE.md, …) survive the first volume mount.
if [ -n "${RP_VOLUMES:-}" ] && [ -n "${RP_USER:-}" ]; then
    seed_root=/usr/local/share/rp/seed
    IFS=',' read -ra _vols <<<"$RP_VOLUMES"
    for v in "${_vols[@]}"; do
        mount_path=${v%%=*}
        vol_name=${v#*=}
        [ -z "$mount_path" ] && continue
        if [ ! -d "$mount_path" ]; then
            echo "rp-init: WARN volume mount $mount_path missing; skipping" >&2
            continue
        fi
        # Merge-seed: for each file in the image stash, copy it into the
        # mounted volume IF the destination is missing. Existing files in
        # the volume (agent writes from a prior session, host_files
        # overrides) are preserved. New seed files (e.g. plugins added in
        # a profile update + image rebuild) get pulled in on next create.
        # Cost: one find walk per create, only on volumes the profile
        # actually stashed seed content for.
        if [ -d "$seed_root/$vol_name" ]; then
            (cd "$seed_root/$vol_name" && find . \( -type f -o -type l \) -print) \
                | while IFS= read -r rel; do
                    rel=${rel#./}
                    target="$mount_path/$rel"
                    if [ ! -e "$target" ]; then
                        mkdir -p "$(dirname "$target")"
                        cp -a "$seed_root/$vol_name/$rel" "$target"
                    fi
                done
            echo "rp-init: merge-seeded volume $vol_name from $seed_root/$vol_name" >&2
        fi
        chown -R "$RP_USER:$RP_USER" "$mount_path" 2>/dev/null || true
    done
fi

# host_path_aliases: per-path symlinks (host_path → container_path).
# RP_PATH_ALIASES is comma-separated `host:container` pairs from
# resolve-create-args.sh. Each is created as a symlink so host-absolute
# references baked into settings.json / hooks resolve through.
# Idempotent: skip if the host path already exists.
if [ -n "${RP_PATH_ALIASES:-}" ]; then
    IFS=',' read -ra _aliases <<<"$RP_PATH_ALIASES"
    for spec in "${_aliases[@]}"; do
        host_path=${spec%%:*}
        cont_path=${spec#*:}
        [ -z "$host_path" ] || [ -z "$cont_path" ] && continue
        if [ "$host_path" = "$cont_path" ]; then
            continue
        fi
        if [ -e "$host_path" ] || [ -L "$host_path" ]; then
            echo "rp-init: $host_path already exists (alias skipped)" >&2
            continue
        fi
        mkdir -p "$(dirname "$host_path")"
        # The target dir is created if missing so the symlink resolves
        # immediately (claude reads the link target and fails if it doesn't
        # exist yet). Owner = RP_USER so the agent can write into it.
        if [ ! -e "$cont_path" ]; then
            mkdir -p "$cont_path"
            chown "$RP_USER:$RP_USER" "$cont_path" 2>/dev/null || true
        fi
        ln -s "$cont_path" "$host_path"
        echo "rp-init: aliased $host_path → $cont_path" >&2
    done
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

echo "rp-init: launching rp-fuse with $slot mount(s)" >&2
exec /usr/local/bin/rp-fuse \
    --shadow "$SHADOW" \
    "${FUSE_ARGS[@]}" \
    $CACHE_FLAG \
    $DEBUG_FLAG
