#!/usr/bin/env bash
# ADR-0024: agent state lifetime.
#
# Property: two worktree containers of one repo get separate claude-home
# volumes (session state, credentials) but share one repo-scoped
# claude-memory volume, which Claude Code uses through autoMemoryDirectory
# in root-owned managed settings. The memory volume outlives a container.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

base=$(mk_probe agent-state)
g init -q "$base/rpstate"
(cd "$base/rpstate" && "$RP" init >/dev/null)
g -C "$base/rpstate" add -A
g -C "$base/rpstate" commit -q -m init
g -C "$base/rpstate" worktree add -q -b a "$base/rpstate-a"
g -C "$base/rpstate" worktree add -q -b b "$base/rpstate-b"

ca=$(container_name claude-code rpstate-a)
cb=$(container_name claude-code rpstate-b)
remember_container "$ca"
remember_container "$cb"

for wt in a b; do
    cd "$base/rpstate-$wt"
    out=$("$RP" create 2>&1) || fail "rp create in rpstate-$wt failed: $out"
done
container start "$ca" >/dev/null 2>&1 || true
container start "$cb" >/dev/null 2>&1 || true

as_coder() { container exec -u coder --workdir /home/coder "$@"; }

# Managed settings: root-owned, read-only for the agent, point at the volume.
out=$(as_coder "$ca" stat -c '%U %a' /etc/claude-code/managed-settings.json 2>&1)
assert_eq "$out" "root 644" "managed settings are root-owned"
out=$(as_coder "$ca" cat /etc/claude-code/managed-settings.json 2>&1)
assert_contains "$out" '"autoMemoryDirectory": "~/.claude-memory"' "managed settings set autoMemoryDirectory"
as_coder "$ca" sh -c 'grep -aq autoMemoryDirectory "$(readlink -f ~/.local/bin/claude)"' \
    || fail "installed Claude Code does not know autoMemoryDirectory"

# Memory is shared between the worktree containers ...
as_coder "$ca" sh -c 'echo "learned-in-a" > .claude-memory/MEMORY.md' \
    || fail "could not write to ~/.claude-memory in $ca"
out=$(as_coder "$cb" cat .claude-memory/MEMORY.md 2>&1)
assert_eq "$out" "learned-in-a" "worktree b sees worktree a's memory"

# ... while ~/.claude (session state) is not.
as_coder "$ca" sh -c 'echo session-a > .claude/rp-session-marker' \
    || fail "could not write to ~/.claude in $ca"
if as_coder "$cb" test -e .claude/rp-session-marker; then
    fail "claude-home is shared between worktree containers"
fi

# Host layout: one repo dir holding the memory, one workspace dir per
# container. RP_VOLUMES_DIR is private to this test.
repo_dirs=("$RP_VOLUMES_DIR"/repos/*)
[ "${#repo_dirs[@]}" -eq 1 ] || fail "expected one repo volume dir, got: ${repo_dirs[*]}"
assert_eq "$(cat "${repo_dirs[0]}/claude-memory/MEMORY.md")" "learned-in-a" "memory on the host"
assert_eq "$(cat "${repo_dirs[0]}/.repo")" "$base/rpstate/.git" "repo metadata names the common dir"
ws_dirs=("$RP_VOLUMES_DIR"/workspaces/*)
[ "${#ws_dirs[@]}" -eq 2 ] || fail "expected two workspace volume dirs, got: ${ws_dirs[*]}"

# Memory outlives the container.
cd "$base/rpstate-a"
"$RP" destroy >/dev/null 2>&1 || fail "rp destroy in rpstate-a failed"
[ -f "${repo_dirs[0]}/claude-memory/MEMORY.md" ] || fail "destroy removed the repo memory"

echo "OK test-agent-state"
