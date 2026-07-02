#!/usr/bin/env bash
# Runs the host-side test-profile-*.sh (rp-fuse binary) and test-wrapper-*.sh
# (the `rp` CLI) in this directory. Skips the rp-fuse binary tests if the host
# binary is missing (CI builds it via rp build-host before invoking this
# runner); wrapper tests need no binary.
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)

failed=0
for t in "$THIS"/test-profile-*.sh "$THIS"/test-wrapper-*.sh; do
    name=$(basename "$t" .sh)
    if bash "$t"; then
        :
    else
        echo "FAIL: $name"
        failed=1
    fi
done

if [ "$failed" -eq 0 ]; then
    echo "ALL HOST PROFILE TESTS PASSED"
else
    echo "HOST PROFILE TESTS FAILED"
    exit 1
fi
