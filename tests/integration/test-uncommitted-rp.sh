#!/usr/bin/env bash
# ADR-0023: worktrees of a repo that doesn't commit .rp/.
#
# Property: a linked worktree without a .rp/ of its own takes the repo
# home's whole .rp/: config.yaml (resources), config.local.yaml
# (host_files) and shadow rules, which hide host content and keep agent
# writes off the host. The agent can't create a .rp/ to switch the
# fallback off. `rp list --json` reports the container by its worktree.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

base=$(mk_probe uncommitted-rp)
g init -q "$base/rpnorp"
echo hello > "$base/rpnorp/README"
g -C "$base/rpnorp" add -A
g -C "$base/rpnorp" commit -q -m init
g -C "$base/rpnorp" worktree add -q -b a "$base/rpnorp-a"

# rp is set up in the main checkout only, and kept out of git.
(cd "$base/rpnorp" && "$RP" init >/dev/null)
echo ".rp/" >> "$base/rpnorp/.git/info/exclude"
cat >> "$base/rpnorp/.rp/config.yaml" <<'EOF'
resources:
  memory: 3G
EOF
echo "from-repo-home" > "$base/marker"
cat > "$base/rpnorp/.rp/config.local.yaml" <<EOF
host_files:
  - src: $base/marker
    dst: /home/{{user}}/rp-fallback-marker
EOF
echo "node_modules/" > "$base/rpnorp/.rp/shadow"
[ ! -e "$base/rpnorp-a/.rp" ] || fail "setup: worktree has a .rp/"
mkdir -p "$base/rpnorp-a/node_modules"
echo host > "$base/rpnorp-a/node_modules/host-file"

ca=$(container_name claude-code rpnorp-a)
remember_container "$ca"
cd "$base/rpnorp-a"
out=$("$RP" create 2>&1) || fail "rp create failed: $out"
case "$out" in *"no resources.memory set"*) fail "repo home config.yaml not applied: $out" ;; esac
container start "$ca" >/dev/null 2>&1 || true
as_coder() { container exec -u coder --workdir "$base/rpnorp-a" "$@"; }

mem=$(container inspect "$ca" | jq -r '.[0].configuration.resources.memoryInBytes')
assert_eq "$mem" "$((3 * 1024 * 1024 * 1024))" "memory from the repo home's config.yaml"
out=$(as_coder "$ca" cat /home/coder/rp-fallback-marker 2>&1)
assert_eq "$out" "from-repo-home" "host_files from the repo home's config.local.yaml"

# Shadow rules from the repo home: host content hidden, writes kept off.
if as_coder "$ca" test -e node_modules/host-file; then
    fail "node_modules/host-file visible: repo home shadow rules not applied"
fi
as_coder "$ca" sh -c 'mkdir -p node_modules && echo agent > node_modules/agent-file' \
    || fail "could not write to the shadowed node_modules"
[ ! -e "$base/rpnorp-a/node_modules/agent-file" ] || fail "shadowed write reached the host"
out=$(as_coder "$ca" cat README 2>&1)
assert_eq "$out" "hello" "unshadowed files pass through"

# The agent can't disable the fallback by creating its own .rp/.
if as_coder "$ca" mkdir .rp 2>/dev/null; then
    fail "agent created .rp/ in the worktree"
fi
[ ! -e "$base/rpnorp-a/.rp" ] || fail ".rp/ appeared on the host"

# Machine-readable listing for tools that manage worktrees.
entry=$("$RP" list --json | jq -c --arg c "$ca" '.[] | select(.container == $c)')
assert_eq "$(jq -r .path <<<"$entry")" "$base/rpnorp-a" "list --json path"
assert_eq "$(jq -r .name <<<"$entry")" "rpnorp-a" "list --json name"
assert_eq "$(jq -r .state <<<"$entry")" "running" "list --json state"
assert_eq "$(jq -r '.workspaces[0].read_only' <<<"$entry")" "false" "list --json workspaces"

echo "OK test-uncommitted-rp"
