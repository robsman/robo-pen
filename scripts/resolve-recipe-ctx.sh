#!/usr/bin/env bash
# Resolve the workspace context for a Justfile recipe.
#
# The rp wrapper parses the user's CLI (`--name`, positional paths,
# `:ro` suffix, `--` extras) and exports:
#   * RP_NAME           — container slug (already final; user-provided
#                         via --name or the repo-scoped default from
#                         scripts/resolve-workspace-name.sh)
#   * RP_PATHS_RAW      — newline-separated workspace specs, each
#                         `<canonical-path>[:ro]`. First line is the
#                         primary workspace (drives image build, labels,
#                         agent/user resolution).
#   * RP_EXTRA_ARGS_RAW — newline-separated extra args destined for
#                         the inner tool (container create / agent CLI).
#
# This helper consumes those env vars and emits shell `export` lines for:
#   WS_PRIMARY      absolute path of the primary workspace (no :ro suffix)
#   NAME            container slug
#   AGENT           configured agent (claude-code default)
#   USER_NAME       configured container user (coder default)
#   PREFIX          container-name prefix: "rp-${AGENT}-"
#   CONT_NAME       full container name: "${PREFIX}${NAME}"
#   REPO_SLUG       slug of the repo the primary workspace belongs to
#   VOLUME_KEY      per-repo key for the volume backing dirs (ADR-0021)
#   IMAGE_TAG       per-project image tag the build emits
#   WS_LIST_TSV     tab-separated workspace specs (one per line, in order)
#   EXTRA_TSV       tab-separated extras (one per line)
#   RP_WORKSPACE_ENV  value for the in-container RP_WORKSPACE env: space-
#                     separated path[:ro] entries (init.sh splits on space).
#
# Usage from a recipe (bash):
#   eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
#
# The single argument is the cwd fallback used when RP_PATHS_RAW is unset
# (allows direct `just <recipe>` invocation without the wrapper).
set -euo pipefail

CWD_FALLBACK=${1:?missing cwd fallback}

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST_BIN="$REPO_DIR/rp-fuse/rp-fuse-darwin-arm64"

primary=""
rp_workspace_env=""
ws_list_tsv=""

if [ -n "${RP_PATHS_RAW:-}" ]; then
    # Parse newline-separated entries (the wrapper already canonicalised
    # each path). First entry is primary.
    first=1
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        ws_list_tsv+="$entry"$'\t'
        if [ "$first" -eq 1 ]; then
            first=0
            primary="${entry%:ro}"
        fi
        if [ -n "$rp_workspace_env" ]; then
            rp_workspace_env+=" "
        fi
        rp_workspace_env+="$entry"
    done <<<"${RP_PATHS_RAW%$'\n'}"
else
    primary=$CWD_FALLBACK
    ws_list_tsv="$primary"$'\t'
    rp_workspace_env=$primary
fi

# Repo slug + default container slug for the primary workspace. Repo-scoped
# so worktrees named `main` in different repos get different containers.
names_out=$( "$REPO_DIR/scripts/resolve-workspace-name.sh" "$primary" ) || exit 1
eval "$names_out"

NAME=${RP_NAME:-$RP_DEFAULT_NAME}
REPO_SLUG=$RP_REPO_SLUG

# Agent + user from the primary workspace's .rp/config.yaml. Both fall
# back to their respective defaults if the binary or file is missing.
AGENT=$(
    if [ -x "$HOST_BIN" ]; then
        "$HOST_BIN" config --file "$primary/.rp/config.yaml" field agent 2>/dev/null || true
    fi
)
[ -z "$AGENT" ] && AGENT=claude-code

USER_NAME=$(
    if [ -x "$HOST_BIN" ]; then
        "$HOST_BIN" config --file "$primary/.rp/config.yaml" field user 2>/dev/null || true
    fi
)
[ -z "$USER_NAME" ] && USER_NAME=coder

PREFIX="rp-${AGENT}-"
CONT_NAME="${PREFIX}${NAME}"
IMAGE_TAG="${CONT_NAME}:latest-rp"

# Volume backing dirs are keyed by repo, not by container, so every
# worktree of one repo reuses the same agent state (one `rp login` covers
# them all). Independent of --name on purpose: the state belongs to the
# repo. Override with RP_VOLUME_KEY. See ADR-0021.
VOLUME_KEY=${RP_VOLUME_KEY:-"${PREFIX}${REPO_SLUG}"}

extra_tsv=""
if [ -n "${RP_EXTRA_ARGS_RAW:-}" ]; then
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        extra_tsv+="$entry"$'\t'
    done <<<"${RP_EXTRA_ARGS_RAW%$'\n'}"
fi

# Print export lines using printf-quoting so paths with spaces survive.
printf 'WS_PRIMARY=%q\n' "$primary"
printf 'NAME=%q\n' "$NAME"
printf 'AGENT=%q\n' "$AGENT"
printf 'USER_NAME=%q\n' "$USER_NAME"
printf 'PREFIX=%q\n' "$PREFIX"
printf 'CONT_NAME=%q\n' "$CONT_NAME"
printf 'REPO_SLUG=%q\n' "$REPO_SLUG"
printf 'VOLUME_KEY=%q\n' "$VOLUME_KEY"
printf 'IMAGE_TAG=%q\n' "$IMAGE_TAG"
printf 'WS_LIST_TSV=%q\n' "$ws_list_tsv"
printf 'EXTRA_TSV=%q\n' "$extra_tsv"
printf 'RP_WORKSPACE_ENV=%q\n' "$rp_workspace_env"
