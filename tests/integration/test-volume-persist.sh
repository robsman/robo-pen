#!/usr/bin/env bash
# Property: a persistent volume declared in a profile manifest survives
# `rp destroy && rp create`. The volume is also seeded from
# /usr/local/share/rp/seed/<name>/ when empty on first create, so
# build-time files (settings.json, CLAUDE.md) appear in the volume even
# though the bind shadows the in-image copies.
#
# Setup: claude-code's manifest declares `volumes: [{name: claude-home,
# mount: .claude}]`. The build routes `files:` whose dst falls inside
# /home/coder/.claude/ to the seed dir; init.sh copies them into the
# volume on first start.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe volpersist)
cd "$ws"
"$RP" init >/dev/null

# First create + start. Seed copy + chown happen on this run.
cont=$(rp_create_and_start volpersist)

# (1) Settings.json must appear at the expected path — verifies the
#     seed → volume copy worked.
out=$(container exec -u coder --workdir "/home/coder" "$cont" \
        sh -c 'ls -A .claude && cat .claude/settings.json' 2>&1)
echo "$out" | grep -q 'settings.json' \
    || fail "settings.json not present in /home/coder/.claude after seed: $out"
echo "$out" | grep -q '"' \
    || fail "settings.json content empty: $out"

# (2) Write a session marker as the agent user — simulates `claude login`
#     dropping credentials into the volume.
container exec -u coder --workdir "/home/coder/.claude" "$cont" \
    sh -c 'echo "fake-login-token" > .credentials.json && chmod 0600 .credentials.json' \
    || fail "could not write to /home/coder/.claude (volume not writable)"

# (3) Destroy + recreate. The host backing dir for the volume must
#     preserve the credentials across the cycle.
"$RP" destroy --name volpersist >/dev/null 2>&1 || fail "rp destroy --name volpersist failed"
cont=$(rp_create_and_start volpersist)

post=$(container exec -u coder --workdir "/home/coder/.claude" "$cont" \
        cat .credentials.json 2>&1)
assert_eq "$post" "fake-login-token" "credentials.json content survived destroy+create"

# (4) Verify the host backing dir is where we think it is and contains
#     the expected file. (Volume root is XDG dir under host home.)
host_vol_root=${RP_VOLUMES_DIR:-$HOME/.local/share/robo-pen/volumes}
host_vol="$host_vol_root/$(container_name claude-code volpersist)/claude-home"
[ -f "$host_vol/.credentials.json" ] \
    || fail "credentials.json not found at host backing path $host_vol"

echo "OK test-volume-persist"
