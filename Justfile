set dotenv-load

image := "robo-pen-default"
host_dir := invocation_directory()
host_name := file_name(invocation_directory())

# Agent name for THIS workspace, used to disambiguate parallel containers
# per agent on the same workspace. Resolves at every `just` invocation by
# asking the rp-fuse host binary for the workspace's .rp/config.yaml agent
# field (defaults to claude-code). Falls back to claude-code if the binary
# does not exist yet (e.g. before `rp build-host` on a fresh checkout).
agent := shell(justfile_directory() + "/rp-fuse/rp-fuse-darwin-arm64 config --file " + invocation_directory() + "/.rp/config.yaml field agent 2>/dev/null || echo claude-code")

# Container user for THIS workspace. Same resolution path as `agent`: ask
# the rp-fuse host binary for the .rp/config.yaml user field, default to
# coder when unset. Used by interactive recipes (shell/login/run) so they
# exec as the actual configured user — important when the workspace adopts
# an image's user (e.g. node) instead of creating a fresh coder.
user := shell("u=$(" + justfile_directory() + "/rp-fuse/rp-fuse-darwin-arm64 config --file " + invocation_directory() + "/.rp/config.yaml field user 2>/dev/null || true); echo ${u:-coder}")

# Container prefix is workspace-agent-specific:
#   rp-<agent>-<basename>      e.g. rp-claude-code-myrepo, rp-opencode-myrepo
prefix := "rp-" + agent + "-"

# Generic prefix used by `list` to filter all rp-managed containers regardless
# of which agent they were created with.
list_prefix := "rp-"

# Memory for the long-lived Apple Container builder VM. Effective only at
# `container builder start` — once the builder is up, this is ignored.
# Run `just builder-reset` to apply a new value. 8G is the verified minimum
# for a full base + default-image rebuild + an overlay that runs the
# claude-code profile's install.sh (Node + Claude CLI fetched at overlay time).
builder_memory := "8G"

# ── Apple container setup ────────────────────────────────────────

# Install Apple Container + jq + just, start system services, bring up the builder
setup:
    brew install container jq just
    container system start
    @just builder-ensure

# Start container system services
service-start:
    container system start

# Stop container system services
service-stop:
    container system stop

# Show container system status
service-status:
    container system status

# Ensure the builder VM is running (no-op if already up; use builder-reset to resize)
builder-ensure:
    #!/usr/bin/env bash
    set -euo pipefail
    if container list -a -q | grep -qx buildkit; then
        state=$(container inspect buildkit | jq -r '.[0].status.state')
        if [ "$state" != "running" ]; then
            container builder start -m {{builder_memory}}
        fi
    else
        container builder start -m {{builder_memory}}
    fi

# Delete + recreate the builder VM at the current `builder_memory` size
builder-reset:
    -container builder stop 2>/dev/null
    -container builder delete 2>/dev/null
    container builder start -m {{builder_memory}}

# ── Image ─────────────────────────────────────────────────────────

# Build rp-base (minimal image with rp-fuse + init script); see ADR-0006
build-base: builder-ensure
    container build \
        -f {{justfile_directory()}}/Dockerfile.base \
        -t rp-base \
        {{justfile_directory()}}

# Build the default robo-pen-default image (rp-base + Node/Python/R/DuckDB/just); no agent baked in
build: build-base
    container build -t {{image}} {{justfile_directory()}}

# Rebuild both rp-base and robo-pen-default from scratch, no cache.
rebuild: builder-ensure
    container build --no-cache \
        -f {{justfile_directory()}}/Dockerfile.base \
        -t rp-base \
        {{justfile_directory()}}
    container build --no-cache -t {{image}} {{justfile_directory()}}

# Cross-build the host-side rp-fuse binary (darwin/arm64), used by `rp lint`
build-host:
    container run --rm \
        -v "{{justfile_directory()}}/rp-fuse":/src \
        -w /src \
        -e GOOS=darwin -e GOARCH=arm64 -e CGO_ENABLED=0 \
        golang:1.22-alpine \
        go build -o /src/rp-fuse-darwin-arm64 -ldflags "-s -w" .
    @echo "Built {{justfile_directory()}}/rp-fuse/rp-fuse-darwin-arm64"

# Run the host-side shell integration tests (profile loader, lint, env-forwarding)
test-host: build-host
    bash {{justfile_directory()}}/rp-fuse/tests/run-host-tests.sh

# Run the full integration suite — builds probe containers, exercises every
# invariant from ADR-0008. Slow (~minutes); needs Apple Container running.
test-integration: build-host
    bash {{justfile_directory()}}/tests/integration/run-all.sh

# Run Go unit tests for rp-fuse (rules, lint, config, profile).
test-go:
    container run --rm \
        -v "{{justfile_directory()}}/rp-fuse":/src \
        -w /src \
        golang:1.22-alpine \
        go test ./...

# Run the rule-matching benchmarks. Compare fast-path vs negation regex
# (ADR-0011 documents the cliff). Reads numbers from BenchmarkMatch*.
bench-rules:
    container run --rm \
        -v "{{justfile_directory()}}/rp-fuse":/src \
        -w /src \
        golang:1.22-alpine \
        go test -bench=BenchmarkMatch -benchmem -run=^$ -count=1 ./...

# ── Workspace bootstrap ───────────────────────────────────────────

# Initialize .rp/ in the current workspace from .rp.example/.
# Pass --force to overwrite an existing .rp/ (otherwise refuses).
init *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    DEST="{{host_dir}}/.rp"
    SRC="{{justfile_directory()}}/.rp.example"
    force=0
    for f in {{FLAGS}}; do
        case "$f" in
            --force|-f) force=1 ;;
            -*) echo "rp init: unknown flag $f" >&2; exit 2 ;;
        esac
    done
    if [ -e "$DEST" ]; then
        if [ "$force" -eq 1 ]; then
            rm -rf "$DEST"
        else
            echo "rp init: $DEST already exists; pass --force to overwrite, or delete it first" >&2
            exit 1
        fi
    fi
    cp -R "$SRC" "$DEST"
    echo "Initialized $DEST from $SRC"
    echo ""
    echo "Next steps:"
    echo "  \$EDITOR $DEST/shadow         # tune which paths stay container-local"
    echo "  \$EDITOR $DEST/config.yaml    # only needed for non-default agent/image/user"
    echo "  rp lint                       # sanity check"
    echo "  rp create                     # build overlay + start container"

# ── Container lifecycle ───────────────────────────────────────────

# Internal: auto-create container if missing (using context resolved by
# the rp wrapper via RP_NAME / RP_PATHS_RAW env vars; cwd fallback if
# called via `just` directly), else verify its recorded host_path label
# matches the primary workspace path. Then ensure it is running. Called
# as a dependency by interactive recipes.
_ensure:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    if ! container list -a -q | grep -qx "$CONT_NAME"; then
        # build-project-image.sh overlays rp-bits + the configured agent
        # profile onto the user's chosen base. The image tag is derived
        # from the container name.
        IMAGE_TAG=$( {{justfile_directory()}}/scripts/build-project-image.sh "$WS_PRIMARY" "$CONT_NAME" )
        eval "$( {{justfile_directory()}}/scripts/resolve-create-args.sh "$WS_PRIMARY" )"
        if [[ "${CREATE_FLAGS}" != *--memory* ]]; then
            echo "rp: warning — no resources.memory set in .rp/config.yaml; Apple Container's 1G default" >&2
            echo "    is enough for the agent shell but tight for typical builds (npm install, cargo, pip)." >&2
            echo "    Add resources.memory: 8G to .rp/config.yaml + 'rp destroy && rp create' to raise it." >&2
        fi
        # Build -v args from WS_LIST_TSV (one entry per tab, each "path[:ro]";
        # container's -v doesn't take :ro — FUSE handles ro inside).
        bind_args=()
        IFS=$'\t' read -r -a ws_entries <<<"${WS_LIST_TSV%$'\t'}"
        for entry in "${ws_entries[@]}"; do
            p=${entry%:ro}
            bind_args+=(-v "$p:$p")
        done
        # Extras from RP_EXTRA_ARGS_RAW (after `--` on the CLI), tab-separated.
        extra_args=()
        if [ -n "$EXTRA_TSV" ]; then
            IFS=$'\t' read -r -a extra_args <<<"${EXTRA_TSV%$'\t'}"
        fi
        container create \
            --name "$CONT_NAME" \
            --cap-add SYS_ADMIN \
            -l "rp.host_path=$WS_PRIMARY" \
            -l "rp.agent=$AGENT" \
            -l rp.managed=true \
            $CONTAINER_ENV \
            $CREATE_FLAGS \
            -e "RP_WORKSPACE=$RP_WORKSPACE_ENV" \
            "${bind_args[@]}" \
            "${extra_args[@]}" \
            "$IMAGE_TAG" > /dev/null
        echo "Auto-created container $CONT_NAME -> $WS_PRIMARY (image $IMAGE_TAG${CREATE_FLAGS:+, $CREATE_FLAGS})" >&2
    else
        recorded=$(container inspect "$CONT_NAME" 2>/dev/null | jq -r '.[0].configuration.labels["rp.host_path"] // empty')
        if [ -n "$recorded" ] && [ "$recorded" != "$WS_PRIMARY" ]; then
            echo "ERROR: container $CONT_NAME is bound to: $recorded" >&2
            echo "       requested primary workspace is:   $WS_PRIMARY" >&2
            echo "" >&2
            echo "Either cd into the recorded path, or use an explicit name:" >&2
            echo "  rp <recipe> --name <other-name>" >&2
            exit 1
        fi
    fi
    state=$(container inspect "$CONT_NAME" 2>/dev/null | jq -r '.[0].status.state' || true)
    if [ "$state" != "running" ]; then
        container start "$CONT_NAME" > /dev/null
    fi

# Create a new container with one or more workspaces bound 1:1 (host path
# = container path). The rp wrapper translates CLI positional paths +
# --name into RP_NAME / RP_PATHS_RAW env vars consumed here. See ADR-0010.
create:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    if container list -a -q | grep -qx "$CONT_NAME"; then
        echo "Container $CONT_NAME already exists. Use 'rp destroy --name $NAME' first."
        exit 1
    fi
    IMAGE_TAG=$( {{justfile_directory()}}/scripts/build-project-image.sh "$WS_PRIMARY" "$CONT_NAME" )
    eval "$( {{justfile_directory()}}/scripts/resolve-create-args.sh "$WS_PRIMARY" )"
    if [[ "${CREATE_FLAGS}" != *--memory* ]]; then
        echo "rp: warning — no resources.memory set in .rp/config.yaml; Apple Container's 1G default" >&2
        echo "    is enough for the agent shell but tight for typical builds (npm install, cargo, pip)." >&2
        echo "    Add resources.memory: 8G to .rp/config.yaml + 'rp destroy && rp create' to raise it." >&2
    fi
    bind_args=()
    IFS=$'\t' read -r -a ws_entries <<<"${WS_LIST_TSV%$'\t'}"
    for entry in "${ws_entries[@]}"; do
        p=${entry%:ro}
        bind_args+=(-v "$p:$p")
    done
    extra_args=()
    if [ -n "$EXTRA_TSV" ]; then
        IFS=$'\t' read -r -a extra_args <<<"${EXTRA_TSV%$'\t'}"
    fi
    container create \
        --name "$CONT_NAME" \
        --cap-add SYS_ADMIN \
        -l "rp.host_path=$WS_PRIMARY" \
        -l "rp.agent=$AGENT" \
        -l rp.managed=true \
        $CONTAINER_ENV \
        $CREATE_FLAGS \
        -e "RP_WORKSPACE=$RP_WORKSPACE_ENV" \
        "${bind_args[@]}" \
        "${extra_args[@]}" \
        "$IMAGE_TAG"
    echo "Container $CONT_NAME created. Workspaces: $RP_WORKSPACE_ENV (image $IMAGE_TAG${CREATE_FLAGS:+, $CREATE_FLAGS})"

# Start a stopped container
start:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    container start "$CONT_NAME"

# Stop a running container
stop:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    container stop "$CONT_NAME"

# Restart a container
restart:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    container restart "$CONT_NAME"

# Open a shell (auto-creates / auto-starts as needed)
shell: _ensure
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    ws=$(container inspect "$CONT_NAME" 2>/dev/null | jq -r '.[0].configuration.labels["rp.host_path"] // empty')
    container exec -it -u "$USER_NAME" --workdir "$ws" "$CONT_NAME" bash

# Log in to the agent (Claude subscription flow opens a URL to authenticate)
login: _ensure
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    if ! container exec -u "$USER_NAME" "$CONT_NAME" test -x /usr/local/lib/rp/login.sh 2>/dev/null; then
        echo "agent profile has no login flow" >&2
        exit 1
    fi
    ws=$(container inspect "$CONT_NAME" 2>/dev/null | jq -r '.[0].configuration.labels["rp.host_path"] // empty')
    container exec -it -u "$USER_NAME" --workdir "$ws" "$CONT_NAME" /usr/local/lib/rp/login.sh

# Run the agent. Default mode = bypass-permissions (the container is the
# safety boundary). Extras after `--` on the rp CLI are passed to the
# agent's run script. Pass --gated as the FIRST extra to dispatch to
# the profile's run-gated.sh (permission-prompted) script instead.
run: _ensure
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    args=()
    if [ -n "$EXTRA_TSV" ]; then
        IFS=$'\t' read -r -a args <<<"${EXTRA_TSV%$'\t'}"
    fi
    script=/usr/local/lib/rp/run.sh
    if [ "${args[0]:-}" = "--gated" ]; then
        script=/usr/local/lib/rp/run-gated.sh
        args=( "${args[@]:1}" )
        if ! container exec -u "$USER_NAME" "$CONT_NAME" test -x "$script" 2>/dev/null; then
            echo "agent profile is bypass-only (no run-gated.sh)" >&2
            exit 1
        fi
    fi
    ws=$(container inspect "$CONT_NAME" 2>/dev/null | jq -r '.[0].configuration.labels["rp.host_path"] // empty')
    container exec -it -u "$USER_NAME" --workdir "$ws" "$CONT_NAME" "$script" "${args[@]}"

# Copy files from host to container
cp-to name src dest:
    container cp {{src}} {{name}}:{{dest}}

# Copy files from container to host
cp-from name src dest:
    container cp {{name}}:{{src}} {{dest}}

# Stop and remove a container (workspace files on host untouched)
destroy:
    #!/usr/bin/env bash
    set -uo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    container stop "$CONT_NAME" 2>/dev/null || true
    container delete "$CONT_NAME"
    container image rm -f "$IMAGE_TAG" 2>/dev/null || true
    echo "Container $CONT_NAME removed. Workspace files on host untouched."

# ── Info / diagnostics ────────────────────────────────────────────

# List all rp-managed containers (grouped by workspace path, with agent column)
list:
    #!/usr/bin/env bash
    set -u
    {
        printf "WORKSPACE\tAGENT\tNAME\tSTATUS\n"
        container list -a -q 2>/dev/null | grep "^{{list_prefix}}" 2>/dev/null | (while read -r n; do
            container inspect "$n" 2>/dev/null \
                | jq -r --arg n "$n" '.[0] | [
                    (.configuration.labels["rp.host_path"] // "-"),
                    (.configuration.labels["rp.agent"] // "-"),
                    $n,
                    .status.state
                ] | @tsv'
        done | sort) || true
    } | column -t -s $'\t'

# Show container logs
logs:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    container logs "$CONT_NAME"

# Show resource usage for all containers
stats:
    container stats
