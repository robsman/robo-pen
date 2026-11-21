#!/usr/bin/env bash
# Resolve the workspace context for a Justfile recipe.
#
# The rp wrapper parses the user's CLI (`--name`, positional paths,
# `:ro` suffix, `--` extras) and exports:
#   * RP_NAME           — container slug, only when the user passed --name
#   * RP_LOOKUP_ONLY    — 1 for recipes that need an existing container
#                         (shell, stop, destroy, ...): no new name is chosen
#   * RP_PATHS_RAW      — newline-separated workspace specs, each
#                         `<canonical-path>[:ro]`. First line is the
#                         primary workspace (drives image build, labels,
#                         agent/user resolution).
#   * RP_EXTRA_ARGS_RAW — newline-separated extra args destined for
#                         the inner tool (container create / agent CLI).
#
# This helper consumes those env vars and emits shell `export` lines for:
#   WS_PRIMARY      absolute path of the primary workspace (no :ro suffix)
#   NAME            container slug (CONT_NAME without PREFIX)
#   NAME_EXPLICIT   1 if the name came from --name, else 0
#   AGENT           configured agent (claude-code default)
#   USER_NAME       configured container user (coder default)
#   PREFIX          container-name prefix: "rp-${AGENT}-"
#   CONT_NAME       full container name: "${PREFIX}${NAME}". Without
#                   --name, the existing container whose rp.host_path is
#                   WS_PRIMARY, else a new name per ADR-0021
#   WORKSPACE_KEY   on-disk key for per-workspace state (ADR-0021)
#   REPO_KEY        on-disk key for per-repo state; empty for non-git
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
#
# On failure it prints `exit 1` to stdout, because `eval "$(...)"` would
# otherwise swallow the error and run the recipe with empty variables.
set -euo pipefail
trap '[ $? -ne 0 ] && echo "exit 1"' EXIT

CWD_FALLBACK=${1:?missing cwd fallback}

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/scripts/lib-identity.sh"
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
if [ -n "${RP_NAME:-}" ]; then
    NAME=$RP_NAME
    NAME_EXPLICIT=1
else
    NAME_EXPLICIT=0
    index=$(rp_container_index)
    CONT_NAME=$(rp_find_container "$index" "$primary" "$AGENT")
    if [ -n "$CONT_NAME" ]; then
        NAME=${CONT_NAME#"$PREFIX"}
    elif [ "${RP_LOOKUP_ONLY:-0}" = "1" ]; then
        echo "rp: no $AGENT container for $primary" >&2
        echo "    run 'rp list' to see containers, or pass --name <name>" >&2
        exit 1
    else
        NAME=$(rp_free_name "$index" "$PREFIX" "$primary")
    fi
fi
CONT_NAME="${PREFIX}${NAME}"
IMAGE_TAG="${CONT_NAME}:latest-rp"
WORKSPACE_KEY=$(rp_workspace_key "$CONT_NAME" "$primary")
rp_git_info "$primary"
REPO_KEY=""
if [ -n "$RP_GIT_COMMON" ]; then
    REPO_KEY=$(rp_repo_key "$RP_GIT_COMMON")
fi

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
printf 'NAME_EXPLICIT=%q\n' "$NAME_EXPLICIT"
printf 'AGENT=%q\n' "$AGENT"
printf 'USER_NAME=%q\n' "$USER_NAME"
printf 'PREFIX=%q\n' "$PREFIX"
printf 'CONT_NAME=%q\n' "$CONT_NAME"
printf 'IMAGE_TAG=%q\n' "$IMAGE_TAG"
printf 'WORKSPACE_KEY=%q\n' "$WORKSPACE_KEY"
printf 'REPO_KEY=%q\n' "$REPO_KEY"
printf 'WS_LIST_TSV=%q\n' "$ws_list_tsv"
printf 'EXTRA_TSV=%q\n' "$extra_tsv"
printf 'RP_WORKSPACE_ENV=%q\n' "$rp_workspace_env"
