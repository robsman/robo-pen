#!/usr/bin/env bash
# Run every tests/integration/test-*.sh. Each test self-cleans via trap. We
# don't run in parallel — Apple Container's builder VM serialises image
# builds anyway.
set -euo pipefail

THIS=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$THIS/../.." && pwd)

if [ ! -x "$REPO/rp-fuse/rp-fuse-darwin-arm64" ]; then
    echo "FAIL: host rp-fuse binary missing; run 'rp build-host' first" >&2
    exit 1
fi
if ! container system status 2>/dev/null | grep -qi "running"; then
    echo "FAIL: Apple Container system not running; run 'rp service-start'" >&2
    exit 1
fi

# Second line of defence behind each test's own trap: every container a
# test registers is also written to a suite-wide ledger, and all probe dirs
# live under one suite dir. Both are swept on exit, including Ctrl-C and
# tests that were killed before their trap could run.
. "$THIS/lib-sweep.sh"
export RP_TEST_TMP=$(mktemp -d /tmp/rp-integration-suite.XXXXXX)
export RP_TEST_LEDGER="$RP_TEST_TMP/containers"
: > "$RP_TEST_LEDGER"
# Outside RP_TEST_TMP, which sweep_suite deletes before reading it.
images_before=$(mktemp)
project_images > "$images_before"
trap 'sweep_suite "$RP_TEST_LEDGER" "$RP_TEST_TMP" "$images_before"; rm -f "$images_before"' EXIT
trap "exit 130" INT TERM HUP

failed=0
passed=0
for t in "$THIS"/test-*.sh; do
    name=$(basename "$t" .sh)
    echo "--- $name ---"
    if bash "$t"; then
        passed=$((passed+1))
    else
        echo "FAIL: $name"
        failed=$((failed+1))
    fi
    echo ""
done

echo "================================"
echo "passed=$passed failed=$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
