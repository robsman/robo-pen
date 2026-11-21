#!/usr/bin/env bash
# Cleanup helpers shared by lib.sh (per test) and run-all.sh (per suite).
# Defines functions only: lib.sh creates a probe dir and installs traps as
# soon as it is sourced, which run-all.sh must not trigger.

# Prints every project image ref (rp-img-*, rp-src-*; ADR-0022), sorted.
project_images() {
    container image list 2>/dev/null \
        | awk 'NR>1 && ($1 ~ /^rp-img-/ || $1 ~ /^rp-src-/) {print $1 ":" $2}' \
        | LC_ALL=C sort -u
}

# Usage: remove_new_images <snapshot-file>
# Removes project images not listed in the snapshot. An image still used by
# a container can't be removed, so the user's own containers keep theirs.
remove_new_images() {
    local ref
    [ -f "$1" ] || return 0
    LC_ALL=C comm -13 "$1" <(project_images) | while read -r ref; do
        container image rm "$ref" >/dev/null 2>&1 || true
    done
}

# Usage: sweep_suite <ledger> <suite-tmp-dir> <images-snapshot>
# Removes every container named in the ledger and every project image
# created since the snapshot, deletes the suite dir, and reports anything
# that is still there afterwards.
sweep_suite() {
    local ledger="$1" dir="$2" images="$3" c left=()
    if [ -f "$ledger" ]; then
        for c in $(sort -u "$ledger"); do
            container delete --force "$c" >/dev/null 2>&1 || true
            if container inspect "$c" >/dev/null 2>&1; then
                left+=("$c")
            fi
        done
    fi
    remove_new_images "$images"
    if [ -f "$images" ]; then
        while read -r c; do
            left+=("$c")
        done < <(LC_ALL=C comm -13 "$images" <(project_images))
    fi
    rm -rf "$dir"
    if [ "${#left[@]}" -gt 0 ]; then
        echo "WARN: integration cleanup left resources behind: ${left[*]}" >&2
    else
        echo "cleanup: all test containers, images and volumes removed"
    fi
}
