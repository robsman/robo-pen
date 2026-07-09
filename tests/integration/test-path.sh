#!/usr/bin/env bash
# Bug class 3: agent binary on PATH after overlay build.
#
# Property: the configured container user's PATH includes
# /home/<user>/.local/bin so that agent installers (claude.ai, opencode.ai)
# leave their binary callable from `container exec -u <user>`.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# Case A: default base image (robo-pen-default).
ws=$(mk_probe path-default)
cd "$ws"
"$RP" init >/dev/null
cont=$(rp_create_and_start path-default)

out=$(container exec -u coder "$cont" sh -c 'which claude && claude --version' 2>&1)
assert_contains "$out" "/home/coder/.local/bin/claude" "default image PATH"
assert_contains "$out" "Claude Code" "claude --version output"

# Case B: devcontainer base image — must also have the path baked.
ws=$(mk_probe path-devc)
cd "$ws"
"$RP" init >/dev/null
cat > .rp/config.yaml <<EOF
image: mcr.microsoft.com/devcontainers/javascript-node:24
user: coder
EOF
cont=$(rp_create_and_start path-devc)

out=$(container exec -u coder "$cont" sh -c 'which claude && claude --version' 2>&1)
assert_contains "$out" "/home/coder/.local/bin/claude" "devcontainer image PATH"
assert_contains "$out" "Claude Code" "devcontainer claude --version output"

echo "OK test-path"
