#!/usr/bin/env bash
# Installs the Claude Code CLI. Runs as the configured container user during
# overlay build. Must be idempotent and rely on user-writable paths only — no
# sudo is available.
set -euo pipefail

curl -fsSL https://claude.ai/install.sh | bash

# ADR-0024: auto-memory goes to the claude-memory volume via
# autoMemoryDirectory in managed settings. Claude Code doesn't document
# the version that added the setting, so check the installed binary for
# it and warn (memory then stays in the per-workspace ~/.claude volume).
claude_bin=$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null || true)
if [ -n "$claude_bin" ] && ! grep -aq autoMemoryDirectory "$claude_bin"; then
    echo "WARN: $("$claude_bin" --version 2>/dev/null) does not know autoMemoryDirectory;" \
         "auto-memory stays per workspace instead of per repo" >&2
fi
