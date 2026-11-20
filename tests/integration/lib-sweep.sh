#!/usr/bin/env bash
# Suite-level cleanup for run-all.sh. Kept separate from lib.sh, which
# creates a probe dir and installs traps as soon as it is sourced.

# Usage: sweep_suite <ledger> <suite-tmp-dir>
# Removes every container and image named in the ledger, deletes the suite
# dir, and reports anything that is still there afterwards.
sweep_suite() {
    local ledger="$1" dir="$2" c left=()
    if [ -f "$ledger" ]; then
        for c in $(sort -u "$ledger"); do
            container delete --force "$c" >/dev/null 2>&1 || true
            container image rm -f "$c:latest-rp" >/dev/null 2>&1 || true
            if container inspect "$c" >/dev/null 2>&1 \
                || container image inspect "$c:latest-rp" >/dev/null 2>&1; then
                left+=("$c")
            fi
        done
    fi
    rm -rf "$dir"
    if [ "${#left[@]}" -gt 0 ]; then
        echo "WARN: integration cleanup left resources behind: ${left[*]}" >&2
    else
        echo "cleanup: all test containers, images and volumes removed"
    fi
}
