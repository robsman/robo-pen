#!/usr/bin/env bash
# Shared helpers for rp-fuse integration tests. Sourced by every
# tests/integration/test-*.sh script.
#
# Tests run on the macOS host, talk to Apple Container, and exercise rp via
# the real wrapper. They build images, create containers, run assertions, and
# clean up. Each test is responsible for its own probe workspace + container.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RP="$REPO_DIR/rp"
. "$REPO_DIR/tests/integration/lib-sweep.sh"

# Probe state goes in /tmp so the host workspace doesn't get polluted.
# run-all.sh sets RP_TEST_TMP so it can sweep dirs of tests that died hard.
TMPROOT=$(mktemp -d "${RP_TEST_TMP:-/tmp}/rp-integration.XXXXXX")
# Volumes live under TMPROOT, so removing it also removes them instead of
# leaving one dir per probe in ~/.local/share/robo-pen/volumes.
export RP_VOLUMES_DIR="$TMPROOT/volumes"
export RP_LOCK_DIR="$TMPROOT/locks"
# Project images are shared and named by content hash (ADR-0022), so a test
# can't know its image names up front: remove the ones created meanwhile.
project_images > "$TMPROOT/images-before"
trap "cleanup_probes" EXIT
# Route signals through the EXIT trap so an interrupted test still cleans up.
trap "exit 130" INT TERM HUP

# Registered containers go to a file, not an array: rp_create_and_start runs
# inside $(...), and an array appended to in that subshell never reaches
# the EXIT trap in the parent.
PROBE_CONTAINERS_FILE="$TMPROOT/containers"
PROBE_WORKSPACES=()
EXTRA_CLEANUP=()

# Usage: on_cleanup <command>
# Registers an extra cleanup command. Tests must use this instead of their
# own `trap ... EXIT`, which would replace cleanup_probes.
on_cleanup() {
    EXTRA_CLEANUP+=("$1")
}

mk_probe() {
    # Usage: mk_probe <slug>          -> echoes the probe workspace dir.
    # Returns the realpath so the value matches what `invocation_directory()`
    # reports inside Justfile recipes (macOS's /tmp is a symlink to
    # /private/tmp; just resolves it). Without realpath, assertions on
    # the bind-mount path inside the container would mismatch.
    local slug="$1"
    local ws="$TMPROOT/$slug"
    mkdir -p "$ws"
    ws=$(cd "$ws" && pwd -P)
    PROBE_WORKSPACES+=("$ws")
    echo "$ws"
}

# Register a container (and its image) for cleanup. Call it BEFORE
# `rp create`, so a create that fails halfway still gets cleaned up.
remember_container() {
    echo "$1" >> "$PROBE_CONTAINERS_FILE"
    # Suite-wide ledger, swept by run-all.sh as a second line of defence.
    if [ -n "${RP_TEST_LEDGER:-}" ]; then
        echo "$1" >> "$RP_TEST_LEDGER"
    fi
}

# Usage: remove_probe_container <container>
remove_probe_container() {
    # --force lets delete kill a running container in one step. Without
    # it, `container delete` refuses on running containers and the next
    # test sees leftover state.
    container delete --force "$1" >/dev/null 2>&1 || true
}

# Usage: rp_create_and_start <slug>
# Runs rp create + container start so subsequent `container exec` calls work.
# Registers the container for cleanup. Also pre-emptively deletes any
# orphaned container/image from a previous failed run so the test recovers
# cleanly.
rp_create_and_start() {
    local slug="$1"
    local agent="${2:-claude-code}"
    local cont
    cont=$(container_name "$agent" "$slug")
    # Recover from prior failed runs that left state behind.
    container delete --force "$cont" >/dev/null 2>&1 || true
    remember_container "$cont"
    "$RP" create --name "$slug" >/dev/null 2>&1 || fail "rp create --name $slug failed"
    container start "$cont" >/dev/null 2>&1 || fail "container start $cont failed"
    echo "$cont"
}

cleanup_probes() {
    local c
    if [ -f "$PROBE_CONTAINERS_FILE" ]; then
        for c in $(sort -u "$PROBE_CONTAINERS_FILE"); do
            remove_probe_container "$c"
        done
    fi
    remove_new_images "$TMPROOT/images-before"
    for c in "${EXTRA_CLEANUP[@]:-}"; do
        [ -z "$c" ] && continue
        eval "$c" || true
    done
    rm -rf "$TMPROOT"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        fail "expected '$2', got '$1' ($3)"
    fi
}

assert_contains() {
    if ! grep -qF "$2" <<<"$1"; then
        fail "expected substring '$2' in output: $1 ($3)"
    fi
}

# Resolve container name the way Justfile does: rp-<agent>-<basename>.
container_name() {
    local agent="$1"
    local basename="$2"
    echo "rp-${agent}-${basename}"
}
