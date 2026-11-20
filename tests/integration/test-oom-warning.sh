#!/usr/bin/env bash
# Bug class 5: rp create warns about 1G default memory.
#
# Property: when .rp/config.yaml does not set resources.memory, `rp create`
# prints a multi-line warning pointing at the trap. With resources.memory set,
# the warning must NOT appear.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe oom-default)
cd "$ws"
"$RP" init >/dev/null

remember_container "$(container_name claude-code oom-default)"
out=$("$RP" create --name oom-default 2>&1 || true)
assert_contains "$out" "no resources.memory set" "OOM warning fired"

# Now with memory set — warning should NOT appear.
ws=$(mk_probe oom-explicit)
cd "$ws"
"$RP" init >/dev/null
cat >> .rp/config.yaml <<EOF
resources:
  memory: 4G
EOF

remember_container "$(container_name claude-code oom-explicit)"
out=$("$RP" create --name oom-explicit 2>&1 || true)
if grep -q "no resources.memory set" <<<"$out"; then
    fail "OOM warning fired even though resources.memory is set"
fi

echo "OK test-oom-warning"
