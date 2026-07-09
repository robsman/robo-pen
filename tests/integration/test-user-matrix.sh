#!/usr/bin/env bash
# Bug class 4 + 6: user-create matrix.
#
# Property: rp create succeeds for every legitimate (base image × user)
# combination, AND refuses to start a container whose configured user
# violates the shadow-boundary invariants (uid != 0, no sudoers entry).
#
# We don't enumerate the full 3x3 here because building three different
# images takes minutes; instead we run the three diagnostically important
# corners:
#
#   1. default robo-pen-default + default user (coder)        -> should pass
#   2. devcontainer node:22 + user: coder                     -> should pass
#      (image's `node` user has sudo; rp must create a fresh coder)
#   3. devcontainer node:22 + user: node                      -> should FAIL
#      (image's `node` user IS in sudoers; rp must refuse at build)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

run_case() {
    local label="$1" slug="$2" body="$3" expect="$4"     # expect=pass|fail
    local ws=$(mk_probe "$slug")
    (cd "$ws" && "$RP" init >/dev/null)
    eval "$body" > "$ws/.rp/config.yaml"
    (
        cd "$ws"
        set +e
        out=$("$RP" create --name "$slug" 2>&1)
        ec=$?
        set -e
        if [ "$expect" = "pass" ] && [ "$ec" -ne 0 ]; then
            printf '%s\n' "$out"
            fail "[$label] rp create exited $ec, expected success"
        fi
        if [ "$expect" = "fail" ] && [ "$ec" -eq 0 ]; then
            fail "[$label] rp create unexpectedly succeeded; expected failure (priv user)"
        fi
    )
    # Register the container name so cleanup gets it. All matrix cases use
    # the default agent (claude-code), so name is rp-claude-code-<slug>.
    remember_container "$(container_name claude-code "$slug")"
}

# Case 1: defaults — should pass.
run_case "default" "matrix-default" '
echo "# defaults; agent + image + user all unset"' "pass"

# Case 2: devcontainer + user: coder — should pass (image lacks coder; rp creates).
run_case "devcontainer+coder" "matrix-devc-coder" '
cat <<EOF
image: mcr.microsoft.com/devcontainers/javascript-node:24
user: coder
EOF' "pass"

# Case 3: devcontainer + user: node — should fail (node IS in sudoers).
run_case "devcontainer+node" "matrix-devc-node" '
cat <<EOF
image: mcr.microsoft.com/devcontainers/javascript-node:24
user: node
EOF' "fail"

# Case 4: devcontainer + user: node + strip_sudo: true — should pass.
# ADR-0009 opt-in: overlay strips node's sudo grant during build.
run_case "devcontainer+node+strip_sudo" "matrix-strip-sudo" '
cat <<EOF
image: mcr.microsoft.com/devcontainers/javascript-node:24
user: node
strip_sudo: true
EOF' "pass"

# Verify post-strip the node user actually has no sudo.
container start "$(container_name claude-code matrix-strip-sudo)" >/dev/null 2>&1 || fail "could not start strip-sudo container"
out=$(container exec -u root "$(container_name claude-code matrix-strip-sudo)" sh -c '
    grep -rE "(^|[[:space:]])node([[:space:]]|$)" /etc/sudoers /etc/sudoers.d/ 2>&1 || echo "(no match)"
    id node
' 2>&1)
if ! grep -q "(no match)" <<<"$out"; then
    fail "[devcontainer+node+strip_sudo] node still has a sudoers entry post-strip:\n$out"
fi
if grep -qE 'groups=.*\b(sudo|wheel)\b' <<<"$out"; then
    fail "[devcontainer+node+strip_sudo] node still in sudo/wheel group post-strip:\n$out"
fi

echo "OK test-user-matrix"
