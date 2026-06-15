set dotenv-load

image := "claude-container"
prefix := "claude-"
host_dir := invocation_directory()
host_name := file_name(invocation_directory())

# Memory for the long-lived Apple Container builder VM. Effective only at
# `container builder start` — once the builder is up, this is ignored.
# Run `just builder-reset` to apply a new value. 8G is the verified minimum
# for a full claude-container rebuild including the Claude CLI installer.
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

# Build ccr-base (minimal image with ccr-fuse + init script); see ADR-0006
build-base: builder-ensure
    container build \
        -f {{justfile_directory()}}/Dockerfile.base \
        -t ccr-base \
        {{justfile_directory()}}

# Build the default claude-container image (ccr-base + Node/Python/R/DuckDB/just/Claude CLI)
build: build-base
    container build -t {{image}} {{justfile_directory()}}

# Rebuild both ccr-base and claude-container from scratch, no cache.
rebuild: builder-ensure
    container build --no-cache \
        -f {{justfile_directory()}}/Dockerfile.base \
        -t ccr-base \
        {{justfile_directory()}}
    container build --no-cache -t {{image}} {{justfile_directory()}}

# Cross-build the host-side ccr-fuse binary (darwin/arm64), used by `ccr lint`
build-host:
    container run --rm \
        -v "{{justfile_directory()}}/ccr-fuse":/src \
        -w /src \
        -e GOOS=darwin -e GOARCH=arm64 -e CGO_ENABLED=0 \
        golang:1.22-alpine \
        go build -o /src/ccr-fuse-darwin-arm64 -ldflags "-s -w" .
    @echo "Built {{justfile_directory()}}/ccr-fuse/ccr-fuse-darwin-arm64"

# ── Container lifecycle ───────────────────────────────────────────

# Internal: auto-create container if missing (bound to cwd), else verify its
# recorded host_path label matches cwd. Then ensure it is running. Called as
# a dependency by interactive recipes.
_ensure name=host_name:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! container list -a -q | grep -qx "{{prefix}}{{name}}"; then
        # build-project-image.sh always produces a tag: it overlays ccr-bits +
        # the configured agent profile onto the user's chosen base (image:,
        # build:, .ccr/Dockerfile, or the global default).
        IMAGE_TAG=$( {{justfile_directory()}}/scripts/build-project-image.sh "{{host_dir}}" "{{prefix}}{{name}}" )
        eval "$( {{justfile_directory()}}/scripts/resolve-create-args.sh "{{host_dir}}" )"
        container create \
            --name {{prefix}}{{name}} \
            --cap-add SYS_ADMIN \
            --user 0 \
            -l "ccr.host_path={{host_dir}}" \
            -l ccr.managed=true \
            $CONTAINER_ENV \
            $CREATE_FLAGS \
            -v "{{host_dir}}:/workspace-real" \
            "$IMAGE_TAG" \
            /usr/local/bin/ccr-init.sh > /dev/null
        echo "Auto-created container {{prefix}}{{name}} -> {{host_dir}} (image $IMAGE_TAG${CREATE_FLAGS:+, $CREATE_FLAGS})" >&2
    else
        recorded=$(container inspect {{prefix}}{{name}} 2>/dev/null | jq -r '.[0].configuration.labels["ccr.host_path"] // empty')
        if [ -n "$recorded" ] && [ "$recorded" != "{{host_dir}}" ]; then
            echo "ERROR: container {{prefix}}{{name}} is bound to: $recorded" >&2
            echo "       current directory is:               {{host_dir}}" >&2
            echo "" >&2
            echo "Either cd into the recorded path, or use an explicit name:" >&2
            echo "  ccr <recipe> <other-name>" >&2
            exit 1
        fi
    fi
    state=$(container inspect {{prefix}}{{name}} 2>/dev/null | jq -r '.[0].status.state' || true)
    if [ "$state" != "running" ]; then
        container start {{prefix}}{{name}} > /dev/null
    fi

# Create a new container, bind-mounting the current directory as /workspace
create name=host_name *CONTAINER_ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    if container list -a -q | grep -qx "{{prefix}}{{name}}"; then
        echo "Container {{prefix}}{{name}} already exists. Use 'ccr destroy {{name}}' first."
        exit 1
    fi
    IMAGE_TAG=$( {{justfile_directory()}}/scripts/build-project-image.sh "{{host_dir}}" "{{prefix}}{{name}}" )
    eval "$( {{justfile_directory()}}/scripts/resolve-create-args.sh "{{host_dir}}" )"
    container create \
        --name {{prefix}}{{name}} \
        --cap-add SYS_ADMIN \
        --user 0 \
        -l "ccr.host_path={{host_dir}}" \
        -l ccr.managed=true \
        $CONTAINER_ENV \
        $CREATE_FLAGS \
        -v "{{host_dir}}:/workspace-real" \
        {{CONTAINER_ARGS}} \
        "$IMAGE_TAG" \
        /usr/local/bin/ccr-init.sh
    echo "Container {{prefix}}{{name}} created. Workspace: {{host_dir}} (image $IMAGE_TAG${CREATE_FLAGS:+, $CREATE_FLAGS})"

# Start a stopped container
start name=host_name:
    container start {{prefix}}{{name}}

# Stop a running container
stop name=host_name:
    container stop {{prefix}}{{name}}

# Restart a container
restart name=host_name:
    container restart {{prefix}}{{name}}

# Open a shell (auto-creates / auto-starts as needed)
shell name=host_name: (_ensure name)
    container exec -it -u coder {{prefix}}{{name}} bash

# Log in to the agent (Claude subscription flow opens a URL to authenticate)
login name=host_name: (_ensure name)
    #!/usr/bin/env bash
    set -euo pipefail
    if ! container exec -u coder {{prefix}}{{name}} test -x /usr/local/lib/ccr/login.sh 2>/dev/null; then
        echo "agent profile has no login flow" >&2
        exit 1
    fi
    container exec -it -u coder {{prefix}}{{name}} /usr/local/lib/ccr/login.sh

# Run the agent. Default mode = bypass-permissions (the container is the
# safety boundary). Pass --gated as the FIRST positional arg to dispatch to
# the profile's run-gated.sh (permission-prompted) script instead.
run name=host_name *ARGS: (_ensure name)
    #!/usr/bin/env bash
    set -euo pipefail
    script=/usr/local/lib/ccr/run.sh
    args=( {{ARGS}} )
    if [ "${args[0]:-}" = "--gated" ]; then
        script=/usr/local/lib/ccr/run-gated.sh
        args=( "${args[@]:1}" )
        if ! container exec -u coder {{prefix}}{{name}} test -x "$script" 2>/dev/null; then
            echo "agent profile is bypass-only (no run-gated.sh)" >&2
            exit 1
        fi
    fi
    container exec -it -u coder {{prefix}}{{name}} "$script" "${args[@]}"

# Run the agent in YOLO mode (auto-creates / auto-starts, optional prompt).
# Deprecated — use `ccr run` instead. Removed in Phase E.
claude name=host_name *PROMPT: (_ensure name)
    #!/usr/bin/env bash
    if [ -n "{{PROMPT}}" ]; then
        container exec -it -u coder {{prefix}}{{name}} /usr/local/lib/ccr/run.sh -p "{{PROMPT}}"
    else
        container exec -it -u coder {{prefix}}{{name}} /usr/local/lib/ccr/run.sh
    fi

# Run the agent in permission-gated mode. Deprecated — use `ccr run --gated`.
claude-safe name=host_name *PROMPT: (_ensure name)
    #!/usr/bin/env bash
    if [ -n "{{PROMPT}}" ]; then
        container exec -it -u coder {{prefix}}{{name}} /usr/local/lib/ccr/run-gated.sh -p "{{PROMPT}}"
    else
        container exec -it -u coder {{prefix}}{{name}} /usr/local/lib/ccr/run-gated.sh
    fi

# Copy files from host to container
cp-to name src dest:
    container cp {{src}} {{prefix}}{{name}}:{{dest}}

# Copy files from container to host
cp-from name src dest:
    container cp {{prefix}}{{name}}:{{src}} {{dest}}

# Stop and remove a container (workspace files on host untouched)
destroy name=host_name:
    -container stop {{prefix}}{{name}} 2>/dev/null
    container delete {{prefix}}{{name}}
    @echo "Container {{prefix}}{{name}} removed. Workspace files on host untouched."

# ── Info / diagnostics ────────────────────────────────────────────

# List all claude containers with their workspace path
list:
    #!/usr/bin/env bash
    set -uo pipefail
    {
        printf "NAME\tSTATUS\tWORKSPACE\n"
        container list -a -q 2>/dev/null | grep "^{{prefix}}" 2>/dev/null | while read -r n; do
            container inspect "$n" 2>/dev/null \
                | jq -r --arg n "$n" '.[0] | [$n, .status.state, (.configuration.labels["ccr.host_path"] // "-")] | @tsv'
        done
    } | column -t -s $'\t'

# Show container logs
logs name=host_name:
    container logs {{prefix}}{{name}}

# Show resource usage for all containers
stats:
    container stats
