#!/usr/bin/env bash
# Property: profile's `host_files:` entries copy host source files into
# the container at `rp create` time. Destinations inside a persistent
# volume land in the volume's host backing dir (survive destroy+create);
# destinations outside any volume land in the container layer.
#
# Uses a workspace-level profile override to swap claude-code's
# host_files for test-controlled absolute paths (so we don't depend on
# the actual ~/.claude.json / etc.).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ws=$(mk_probe hostfiles)

# Stage test-controlled host sources OUTSIDE the workspace (inside would
# be FUSE-shadowed and behave differently).
seed_dir=$(mktemp -d /tmp/rp-host-files-src.XXXXXX)
trap "rm -rf '$seed_dir'" EXIT
echo "{\"theme\":\"dark\",\"from\":\"host\"}" > "$seed_dir/settings.json"
echo "# host CLAUDE.md from test" > "$seed_dir/CLAUDE.md"
echo "[user]\n    name = host test" > "$seed_dir/gitconfig"
mkdir -p "$seed_dir/skills"
echo "skill content" > "$seed_dir/skills/example.md"
# Source that intentionally does NOT exist (covers if_missing=skip path).
NONEXISTENT="$seed_dir/does-not-exist"

cd "$ws"
"$RP" init >/dev/null

# Workspace override the claude-code profile with test-controlled
# host_files. The mount target for settings.json + CLAUDE.md lives
# inside the claude-home volume; gitconfig is OUTSIDE any volume
# (container layer); skills land in volume too.
mkdir -p .rp/agents/claude-code
cat > .rp/agents/claude-code/manifest.yaml <<EOF
name: claude-code
description: test-override
env: [ANTHROPIC_API_KEY]
volumes:
  - name: claude-home
    mount: .claude
host_files:
  - src: $seed_dir/settings.json
    dst: /home/{{user}}/.claude/settings.json
  - src: $seed_dir/CLAUDE.md
    dst: /home/{{user}}/.claude/CLAUDE.md
  - src: $seed_dir/gitconfig
    dst: /home/{{user}}/.gitconfig
  - src: $seed_dir/skills
    dst: /home/{{user}}/.claude/skills
  - src: $NONEXISTENT
    dst: /home/{{user}}/.claude/nope.txt
entrypoints:
  install: install.sh
  run: run.sh
  run_gated: run-gated.sh
  login: login.sh
EOF
# Workspace profile overrides need the rest of the bundle. Symlink to
# the builtin so install / run / settings come along.
for name in install.sh run.sh run-gated.sh login.sh settings instructions.md; do
    ln -sfn "$REPO_DIR/agent.profiles/claude-code/$name" ".rp/agents/claude-code/$name"
done

cont=$(rp_create_and_start hostfiles)

# (1) settings.json — host content visible in the container, in the volume.
got=$(container exec -u coder --workdir "/home/coder/.claude" "$cont" cat settings.json 2>&1)
echo "$got" | grep -q 'from-host' || echo "$got" | grep -q '"from":"host"' \
    || fail "settings.json missing host content: $got"

# (2) CLAUDE.md — host content visible.
got=$(container exec -u coder --workdir "/home/coder/.claude" "$cont" cat CLAUDE.md 2>&1)
echo "$got" | grep -q 'host CLAUDE.md from test' \
    || fail "CLAUDE.md missing host content: $got"

# (3) gitconfig — OUTSIDE any volume; lives in container layer.
got=$(container exec -u coder --workdir "/home/coder" "$cont" cat .gitconfig 2>&1)
echo "$got" | grep -q 'host test' \
    || fail ".gitconfig missing host content: $got"

# (4) Directory copy: skills/.
got=$(container exec -u coder --workdir "/home/coder/.claude/skills" "$cont" cat example.md 2>&1)
echo "$got" | grep -q 'skill content' \
    || fail "skills/ directory not copied: $got"

# (5) Missing source did not abort + does not appear in container.
[ -z "$(container exec -u coder --workdir "/home/coder/.claude" "$cont" ls nope.txt 2>&1 | grep -v 'No such')" ] \
    || fail "nope.txt unexpectedly present despite missing host source"

# (6) Persistence across destroy + create — the volume-backed files
# survive (gitconfig in container layer does NOT — that's expected).
container exec -u coder --workdir "/home/coder/.claude" "$cont" \
    sh -c 'echo agent-edit > my-state.json' \
    || fail "could not write to volume"
"$RP" destroy --name hostfiles >/dev/null 2>&1 || fail "rp destroy failed"
cont=$(rp_create_and_start hostfiles)

# Volume-backed files come back (settings.json from host_files copy
# AND the agent's own my-state.json).
got=$(container exec -u coder --workdir "/home/coder/.claude" "$cont" cat settings.json 2>&1)
echo "$got" | grep -q '"from":"host"' \
    || fail "settings.json missing after destroy+create: $got"
got=$(container exec -u coder --workdir "/home/coder/.claude" "$cont" cat my-state.json 2>&1)
assert_eq "$got" "agent-edit" "agent write persisted via volume"

echo "OK test-host-files"
