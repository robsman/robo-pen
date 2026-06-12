set dotenv-load

image := "claude-container"
prefix := "claude-"

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

# Build the container image
build:
    container build -t {{image}} .

# Rebuild without cache
rebuild:
    container build --no-cache -t {{image}} .

# ── Container lifecycle ───────────────────────────────────────────

# Create a new container with bind-mounted project dir
create name *CONTAINER_ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    if container list -a -q | grep -qx "{{prefix}}{{name}}"; then
        echo "Container {{prefix}}{{name}} already exists. Use 'just destroy {{name}}' first."
        exit 1
    fi
    mkdir -p "$(pwd)/projects/{{name}}"
    container create \
        --name {{prefix}}{{name}} \
        -e ANTHROPIC_API_KEY \
        -v "$(pwd)/projects/{{name}}:/workspace" \
        {{CONTAINER_ARGS}} \
        {{image}} \
        sleep infinity
    echo "Container {{prefix}}{{name}} created. Project dir: projects/{{name}}/"

# Start a stopped container
start name:
    container start {{prefix}}{{name}}

# Stop a running container
stop name:
    container stop {{prefix}}{{name}}

# Restart a container
restart name:
    container restart {{prefix}}{{name}}

# Open a shell (auto-starts if stopped)
shell name:
    #!/usr/bin/env bash
    set -euo pipefail
    state=$(container inspect {{prefix}}{{name}} 2>/dev/null | jq -r '.[0].status.state' || true)
    if [ "$state" != "running" ]; then
        container start {{prefix}}{{name}} > /dev/null
    fi
    container exec -it {{prefix}}{{name}} bash

# Log in to Claude with your subscription (opens a URL to authenticate)
login name:
    #!/usr/bin/env bash
    set -euo pipefail
    state=$(container inspect {{prefix}}{{name}} 2>/dev/null | jq -r '.[0].status.state' || true)
    if [ "$state" != "running" ]; then
        container start {{prefix}}{{name}} > /dev/null
    fi
    container exec -it {{prefix}}{{name}} claude login

# Run Claude in YOLO mode (auto-starts, optional prompt)
claude name *PROMPT:
    #!/usr/bin/env bash
    set -euo pipefail
    state=$(container inspect {{prefix}}{{name}} 2>/dev/null | jq -r '.[0].status.state' || true)
    if [ "$state" != "running" ]; then
        container start {{prefix}}{{name}} > /dev/null
    fi
    if [ -n "{{PROMPT}}" ]; then
        container exec -it {{prefix}}{{name}} claude --dangerously-skip-permissions -p "{{PROMPT}}"
    else
        container exec -it {{prefix}}{{name}} claude --dangerously-skip-permissions
    fi

# Run Claude in normal (permission-prompting) mode
claude-safe name *PROMPT:
    #!/usr/bin/env bash
    set -euo pipefail
    state=$(container inspect {{prefix}}{{name}} 2>/dev/null | jq -r '.[0].status.state' || true)
    if [ "$state" != "running" ]; then
        container start {{prefix}}{{name}} > /dev/null
    fi
    if [ -n "{{PROMPT}}" ]; then
        container exec -it {{prefix}}{{name}} claude -p "{{PROMPT}}"
    else
        container exec -it {{prefix}}{{name}} claude
    fi

# Copy files from host to container
cp-to name src dest:
    container cp {{src}} {{prefix}}{{name}}:{{dest}}

# Copy files from container to host
cp-from name src dest:
    container cp {{prefix}}{{name}}:{{src}} {{dest}}

# Stop and remove a container (project files preserved on host)
destroy name:
    -container stop {{prefix}}{{name}} 2>/dev/null
    container delete {{prefix}}{{name}}
    @echo "Container removed. Project files preserved in projects/{{name}}/"

# ── Info / diagnostics ────────────────────────────────────────────

# List all claude containers
list:
    #!/usr/bin/env bash
    container list -a | awk 'NR==1 || /^{{prefix}}/ { print $1"\t"$NF"\t"$2 }'

# Show container logs
logs name:
    container logs {{prefix}}{{name}}

# Show resource usage for all containers
stats:
    container stats
