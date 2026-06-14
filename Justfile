set dotenv-load

image := "claude-container"
prefix := "claude-"
host_dir := invocation_directory()
host_name := file_name(invocation_directory())
build_memory := "8G"

# ── Apple container setup ────────────────────────────────────────

# Install Apple container CLI + jq (for state detection) and start the system services
setup:
    brew install container jq
    container system start

# Start container system services
service-start:
    container system start

# Stop container system services
service-stop:
    container system stop

# Show container system status
service-status:
    container system status

# ── Image ─────────────────────────────────────────────────────────

# Build ccr-base — minimal image holding ccr-fuse + init script + the bits
# the ccr overlay needs. Required before `build` and before any per-project
# image build. See ADR-0006.
build-base:
    container build -m {{build_memory}} \
        -f {{justfile_directory()}}/Dockerfile.base \
        -t ccr-base \
        {{justfile_directory()}}

# Build the default claude-container image (ccr-base + Node/Python/R/DuckDB/
# just/Claude CLI). Used by workspaces with no .ccr/config.yaml or .ccr/Dockerfile.
build: build-base
    container build -m {{build_memory}} -t {{image}} {{justfile_directory()}}

# Rebuild both ccr-base and claude-container from scratch, no cache.
rebuild:
    container build -m {{build_memory}} --no-cache \
        -f {{justfile_directory()}}/Dockerfile.base \
        -t ccr-base \
        {{justfile_directory()}}
    container build -m {{build_memory}} --no-cache -t {{image}} {{justfile_directory()}}

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
        container create \
            --name {{prefix}}{{name}} \
            --cap-add SYS_ADMIN \
            --user 0 \
            -l "ccr.host_path={{host_dir}}" \
            -l ccr.managed=true \
            -e ANTHROPIC_API_KEY \
            -v "{{host_dir}}:/workspace-real" \
            {{image}} \
            /usr/local/bin/ccr-init.sh > /dev/null
        echo "Auto-created container {{prefix}}{{name}} -> {{host_dir}}" >&2
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
    container create \
        --name {{prefix}}{{name}} \
        --cap-add SYS_ADMIN \
        --user 0 \
        -l "ccr.host_path={{host_dir}}" \
        -l ccr.managed=true \
        -e ANTHROPIC_API_KEY \
        -v "{{host_dir}}:/workspace-real" \
        {{CONTAINER_ARGS}} \
        {{image}} \
        /usr/local/bin/ccr-init.sh
    echo "Container {{prefix}}{{name}} created. Workspace: {{host_dir}}"

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

# Log in to Claude with your subscription (opens a URL to authenticate)
login name=host_name: (_ensure name)
    container exec -it -u coder {{prefix}}{{name}} claude login

# Run Claude in YOLO mode (auto-creates / auto-starts, optional prompt)
claude name=host_name *PROMPT: (_ensure name)
    #!/usr/bin/env bash
    if [ -n "{{PROMPT}}" ]; then
        container exec -it -u coder {{prefix}}{{name}} claude --dangerously-skip-permissions -p "{{PROMPT}}"
    else
        container exec -it -u coder {{prefix}}{{name}} claude --dangerously-skip-permissions
    fi

# Run Claude in normal (permission-prompting) mode
claude-safe name=host_name *PROMPT: (_ensure name)
    #!/usr/bin/env bash
    if [ -n "{{PROMPT}}" ]; then
        container exec -it -u coder {{prefix}}{{name}} claude -p "{{PROMPT}}"
    else
        container exec -it -u coder {{prefix}}{{name}} claude
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
