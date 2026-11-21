#!/usr/bin/env bash
# Runs every test-profile-*.sh (plus test-identity.sh) in this directory against the host rp-fuse
# binary. Skips if the host binary is missing (CI builds it via rp build-host
# before invoking this runner).
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)

failed=0
for t in "$THIS"/test-profile-*.sh "$THIS"/test-identity.sh; do
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
