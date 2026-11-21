set dotenv-load

image := "rp-default"
host_dir := invocation_directory()
host_name := file_name(invocation_directory())

# Pre-built images live at ghcr.io/<owner>/{rp-system,rp-default}.
# Image tag picks the wrapper's embedded RP_VERSION when it's a real
# release tag (vX.Y.Z); for source-installed copies (RP_VERSION="dev")
# fall back to :latest. Explicit RP_IMAGE_TAG overrides both. This pins
# a brew-installed rp to images built from the same source tree.
registry_owner := env_var_or_default("RP_REGISTRY_OWNER", "robsman")
rp_version := env_var_or_default("RP_VERSION", "dev")
default_image_tag := if rp_version =~ "^v[0-9]" { rp_version } else { "latest" }
image_tag := env_var_or_default("RP_IMAGE_TAG", default_image_tag)
ghcr_system := "ghcr.io/" + registry_owner + "/rp-system:" + image_tag
ghcr_default := "ghcr.io/" + registry_owner + "/rp-default:" + image_tag

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
#   rp-<agent>-<name>      e.g. rp-claude-code-myrepo, rp-opencode-myrepo-feat
# where <name> comes from the git repo and worktree (ADR-0021).
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

# Install Apple Container + jq + just, start system services, pull (or
# build) the rp-system + rp-default images, and bring up the builder.
#
# Default path pulls ghcr.io/<owner>/{rp-system,rp-default}:latest —
# saves ~15 min on first run. Set RP_BUILD_FROM_SOURCE=1 to force local
# builds instead (needed for dev work on the Dockerfiles themselves).
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    # Skip the brew step entirely when all three deps are already on PATH.
    # The brew formula declares container/jq/just as `depends_on`, so a
    # `brew install robsman/tap/robo-pen` always lands here with everything
    # already installed; calling `brew install` again is a no-op but emits
    # ~10 lines of "Auto-updating Homebrew" + "X is already installed"
    # noise. Source-install users hit the brew path only when something's
    # actually missing.
    if command -v container >/dev/null 2>&1 \
            && command -v jq >/dev/null 2>&1 \
            && command -v just >/dev/null 2>&1; then
        echo "rp setup: container, jq, just already present — skipping brew" >&2
    else
        brew install container jq just
    fi
    container system start
    just builder-ensure
    if [ "${RP_BUILD_FROM_SOURCE:-0}" = "1" ]; then
        echo "rp setup: RP_BUILD_FROM_SOURCE=1 — building images locally" >&2
        just build
    else
        just pull-images || {
            echo "rp setup: pull failed; falling back to local build" >&2
            just build
        }
    fi
    echo ""
    echo "rp setup complete. Try: cd <project> && rp init && rp run"

# Start container system services
service-start:
    container system start

# Stop container system services
service-stop:
    container system stop

# Show container system status
service-status:
    container system status

# Internal: bring the Apple Container apiserver up if it's down. After a host
# reboot the launchd agent sometimes fails to relaunch, leaving every
# `container` call to die with a cryptic XPC "Connection invalid" error — and
# worse, `_ensure` reads the empty `container list` as "container gone" and
# tries to rebuild it. `container system status` exits non-zero only when the
# apiserver is down; `container system start` is a no-op once it is up.
_service-ensure:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! container system status >/dev/null 2>&1; then
        echo "rp: Apple Container service is down — starting it (container system start)" >&2
        container system start
    fi

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

# Pull pre-built rp-system + rp-default from ghcr.io and re-tag them
# both as `<local>:<version>` (versioned, for `rp gc` to enumerate) and as
# `<local>` (no tag = :latest, what the rest of the rp tooling references).
# When the wrapper's RP_VERSION is "dev" the version tag is "latest"; the
# `<local>:<version>` tag and the unversioned tag converge in that case.
#
# Skips the pull when the versioned tag already exists locally — that's
# the safe "this exact image is already here" check (unlike the older
# unversioned check, which couldn't distinguish stale-from-prior-release
# from current).
pull-images:
    #!/usr/bin/env bash
    set -euo pipefail
    pull_and_retag() {
        local remote=$1 local_name=$2 version=$3
        local versioned="${local_name}:${version}"
        if container image inspect "$versioned" >/dev/null 2>&1; then
            echo "rp: $versioned already present locally, skipping pull" >&2
        else
            echo "rp: pulling $remote" >&2
            container image pull "$remote"
            container image tag "$remote" "$versioned"
        fi
        # Always re-point the unversioned name at the just-pulled image so
        # the rest of the tooling sees the current version.
        container image tag "$versioned" "$local_name"
    }
    pull_and_retag {{ghcr_system}} rp-system {{image_tag}}
    pull_and_retag {{ghcr_default}} {{image}} {{image_tag}}

# Build rp-system locally (minimal image with rp-fuse + init script); see ADR-0006.
# Most users want `just pull-images` (much faster). Use this when developing
# on Dockerfile.system or rp-fuse itself.
#
# Also re-tags rp-system:{{image_tag}} (bare -t only produces rp-system:latest).
# create/_ensure COPY --from=rp-system:{{image_tag}} (pinned per commit
# 7045387) — on a brew install image_tag is a real version (e.g. v1.0.10),
# not latest, so without this tag the overlay build can't find the base
# locally and Apple Container mistakes the missing ref for a remote pull.
build-base: builder-ensure
    container build \
        -f {{justfile_directory()}}/Dockerfile.system \
        -t rp-system \
        {{justfile_directory()}}
    container image tag rp-system rp-system:{{image_tag}}

# Build rp-default locally. Standalone (not FROM rp-system — see
# Dockerfile.default), but still depends on build-base: `rp create`'s
# overlay needs a local rp-system:{{image_tag}} to COPY its runtime bits
# from, regardless of which project image (default or custom) it's
# overlaying.
build: build-base
    container build -f {{justfile_directory()}}/Dockerfile.default -t {{image}} {{justfile_directory()}}
    container image tag {{image}} {{image}}:{{image_tag}}

# Force-rebuild both images from scratch, no cache. Pre-built images on
# ghcr.io are NOT touched — this is the "I want a fresh local build" recipe.
rebuild: builder-ensure
    container build --no-cache \
        -f {{justfile_directory()}}/Dockerfile.system \
        -t rp-system \
        {{justfile_directory()}}
    container image tag rp-system rp-system:{{image_tag}}
    container build --no-cache -f {{justfile_directory()}}/Dockerfile.default -t {{image}} {{justfile_directory()}}
    container image tag {{image}} {{image}}:{{image_tag}}

# Remove what short-lived workspaces leave behind (ADR-0025): containers
# and workspace volumes whose folder is gone, and images no container
# uses (project images, legacy *:latest-rp, rp-system/rp-default tags
# other than the current pin and :latest). Shows the list and asks;
# --yes skips the prompt. Repo memory and legacy volume dirs only go with
# --memory / --legacy.
gc *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    RP_GC_KEEP_TAG={{image_tag}} RP_GC_BASE_IMAGES="rp-system {{image}}" \
        {{justfile_directory()}}/scripts/gc.sh {{FLAGS}}

# Destroy ALL rp-managed containers AND remove all rp images (rp-system,
# rp-default, every per-project image). For a full reset after
# a broken state or before uninstalling. Workspace files on host are
# untouched. Aggressive — confirm intent before running on a shared
# machine.
purge:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "${RP_PURGE_YES:-}" != "1" ]; then
        echo "rp purge: this removes ALL rp containers + rp images." >&2
        echo "          Re-run with RP_PURGE_YES=1 to confirm." >&2
        exit 1
    fi
    echo "rp purge: removing rp-managed containers" >&2
    container list -a -q 2>/dev/null \
        | grep '^rp-' \
        | xargs -r -I {} container delete --force {} >/dev/null 2>&1 || true
    echo "rp purge: removing rp images" >&2
    for repo in rp-system {{image}}; do
        container image list 2>/dev/null \
            | awk -v r="$repo" 'NR>1 && $1==r {print $1 ":" $2}' \
            | xargs -r -I {} container image rm -f {} >/dev/null 2>&1 || true
    done
    # Per-project images too (rp-<agent>-<name>:latest-rp pattern).
    container image list 2>/dev/null \
        | awk 'NR>1 && $1 ~ /^rp-/ {print $1 ":" $2}' \
        | xargs -r -I {} container image rm -f {} >/dev/null 2>&1 || true
    # Persistent volume host backing dirs (ADR-0014). Removes login
    # tokens + any agent-local state that survived `rp destroy`.
    vol_root=${RP_VOLUMES_DIR:-$HOME/.local/share/robo-pen/volumes}
    if [ -d "$vol_root" ]; then
        echo "rp purge: removing persistent volume backing at $vol_root" >&2
        rm -rf "$vol_root"
    fi
    echo "rp purge: done"

# Cross-build the host-side rp-fuse binary (darwin/arm64), used by `rp lint`.
# Release tarballs ship a pre-built binary at the expected path, so this
# recipe is mainly for development. Set RP_FORCE_BUILD_HOST=1 to rebuild
# even if a binary is already present.
build-host:
    #!/usr/bin/env bash
    set -euo pipefail
    HOST_BIN={{justfile_directory()}}/rp-fuse/rp-fuse-darwin-arm64
    if [ -x "$HOST_BIN" ] && [ "${RP_FORCE_BUILD_HOST:-0}" != "1" ]; then
        echo "rp: host binary already present at $HOST_BIN (use RP_FORCE_BUILD_HOST=1 to rebuild)" >&2
        exit 0
    fi
    container run --rm \
        -v "{{justfile_directory()}}/rp-fuse":/src \
        -w /src \
        -e GOOS=darwin -e GOARCH=arm64 -e CGO_ENABLED=0 \
        golang:1.22-alpine \
        go build -o /src/rp-fuse-darwin-arm64 -ldflags "-s -w" .
    echo "Built $HOST_BIN"

# Run the host-side shell integration tests (profile loader, lint, env-forwarding)
test-host: build-host
    bash {{justfile_directory()}}/rp-fuse/tests/run-host-tests.sh

# Run the full integration suite — builds probe containers, exercises every
# invariant from ADR-0008. Slow (~minutes); needs Apple Container running.
test-integration: build-host
    bash {{justfile_directory()}}/tests/integration/run-all.sh

# Run Go unit tests for rp-fuse (rules, lint, config, profile). SYS_ADMIN +
# /dev/fuse + fuse3 let the FUSE-mounting tests run instead of skipping.
test-go:
    container run --rm --cap-add SYS_ADMIN \
        -v "{{justfile_directory()}}/rp-fuse":/src \
        -w /src \
        golang:1.22-alpine \
        sh -c '[ -e /dev/fuse ] || mknod /dev/fuse c 10 229; apk add -q fuse3 >/dev/null && go test ./...'

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
_ensure: _service-ensure
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    # Hint only: a folder on an unmounted drive looks deleted, so cleanup
    # waits for an explicit `rp gc` (ADR-0025).
    orphans=$( . {{justfile_directory()}}/scripts/lib-identity.sh && rp_orphan_count )
    if [ "${orphans:-0}" -gt 0 ]; then
        echo "rp: $orphans container(s) belong to folders that no longer exist; 'rp gc' lists and removes them." >&2
    fi
    if ! container list -a -q | grep -qx "$CONT_NAME"; then
        # build-project-image.sh overlays rp-bits + the configured agent
        # profile onto the user's chosen base. The image tag is a hash of
        # its inputs, so an existing image is reused (ADR-0022).
        IMAGE_TAG=$( RP_SYSTEM_TAG={{image_tag}} {{justfile_directory()}}/scripts/build-project-image.sh "$WS_PRIMARY" )
        IMAGE_HASH=${IMAGE_TAG%:latest-rp}
        IMAGE_HASH=${IMAGE_HASH##*-}
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
        # Git stores outside the workspaces, e.g. a worktree's common dir
        # (ADR-0019). Bound 1:1; rp-init mounts :ro ones through rp-fuse.
        git_dirs_env=""
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            p=${entry%:ro}
            bind_args+=(-v "$p:$p")
            git_dirs_env="${git_dirs_env:+$git_dirs_env }$entry"
        done < <( {{justfile_directory()}}/scripts/resolve-git-dirs.sh "${ws_entries[@]}" )
        # Persistent volumes declared by the agent profile (ADR-0014, ADR-0024).
        # mkdirs the host backing dir + emits one TSV line per volume.
        # Forward the (mount\tname) pairs to init.sh via RP_VOLUMES so it
        # can chown + seed each mount on container start.
        volume_pairs=""
        while IFS=$'\t' read -r host_dir cont_mount vol_name; do
            [ -z "$host_dir" ] && continue
            bind_args+=(-v "$host_dir:$cont_mount")
            if [ -n "$volume_pairs" ]; then
                volume_pairs="${volume_pairs},"
            fi
            volume_pairs="${volume_pairs}${cont_mount}=${vol_name}"
        done < <( {{justfile_directory()}}/scripts/resolve-volumes.sh "$WS_PRIMARY" "$AGENT" "$WORKSPACE_KEY" "$REPO_KEY" "$USER_NAME" )
        vol_env=()
        if [ -n "$volume_pairs" ]; then
            vol_env+=(-e "RP_VOLUMES=$volume_pairs")
        fi
        # Extras from RP_EXTRA_ARGS_RAW (after `--` on the CLI), tab-separated.
        extra_args=()
        if [ -n "$EXTRA_TSV" ]; then
            IFS=$'\t' read -r -a extra_args <<<"${EXTRA_TSV%$'\t'}"
        fi
        container create \
            --name "$CONT_NAME" \
            --cap-add SYS_ADMIN \
            -l "rp.host_path=$WS_PRIMARY" \
            -l "rp.name_explicit=$NAME_EXPLICIT" \
            -l "rp.image_hash=$IMAGE_HASH" \
        -l "rp.volume_key=$WORKSPACE_KEY" \
            -l "rp.agent=$AGENT" \
            -l rp.managed=true \
            $CONTAINER_ENV \
            $CREATE_FLAGS \
            -e "RP_WORKSPACE=$RP_WORKSPACE_ENV" \
            -e "RP_GIT_DIRS=$git_dirs_env" \
            "${vol_env[@]+${vol_env[@]}}" \
            "${bind_args[@]}" \
            ${extra_args[@]+"${extra_args[@]}"} \
            "$IMAGE_TAG" > /dev/null
        echo "Auto-created container $CONT_NAME -> $WS_PRIMARY (image $IMAGE_TAG${CREATE_FLAGS:+, $CREATE_FLAGS})" >&2
        # Mark for first-time seeding: the post-start block below copies
        # host_files / host_keychain entries into the container once it
        # finishes booting. See ADR-0015.
        seed_after_start=1
    else
        seed_after_start=0
        recorded=$(container inspect "$CONT_NAME" 2>/dev/null | jq -r '.[0].configuration.labels["rp.host_path"] // empty')
        if [ -n "$recorded" ] && [ "$recorded" != "$WS_PRIMARY" ]; then
            echo "ERROR: container $CONT_NAME is bound to: $recorded" >&2
            echo "       requested primary workspace is:   $WS_PRIMARY" >&2
            echo "" >&2
            echo "Either cd into the recorded path, or use an explicit name:" >&2
            echo "  rp <recipe> --name <other-name>" >&2
            exit 1
        fi
        # Warn when the image inputs changed since create (ADR-0022), e.g.
        # after a branch switch changed .rp/. Never recreate automatically:
        # that would destroy container-local state mid-task.
        recorded_hash=$(container inspect "$CONT_NAME" 2>/dev/null | jq -r '.[0].configuration.labels["rp.image_hash"] // empty')
        if [ -z "$recorded_hash" ]; then
            echo "rp: $CONT_NAME predates hash-tracked images; 'rp recreate' migrates it (login, history and memory are kept)." >&2
        else
            current_hash=$( RP_SYSTEM_TAG={{image_tag}} {{justfile_directory()}}/scripts/build-project-image.sh --hash-only "$WS_PRIMARY" 2>/dev/null || true )
            if [ -n "$current_hash" ] && [ "$current_hash" != "$recorded_hash" ]; then
                echo "rp: the image inputs of $CONT_NAME changed since it was created (.rp/ config, Dockerfile," >&2
                echo "    agent profile or robo-pen version). Run 'rp recreate' to rebuild; workspace volumes are kept." >&2
            fi
        fi
    fi
    state=$(container inspect "$CONT_NAME" 2>/dev/null | jq -r '.[0].status.state' || true)
    if [ "$state" != "running" ]; then
        container start "$CONT_NAME" > /dev/null
    fi
    # Seed host files / Keychain into the just-started container if this
    # was a fresh create. Idempotent if re-run (overwrites with the same
    # content), but cheap to skip for the warm-start path.
    if [ "${seed_after_start:-0}" = "1" ]; then
        {{justfile_directory()}}/scripts/seed-host-files.sh \
            "$WS_PRIMARY" "$AGENT" "$CONT_NAME" "$USER_NAME" "$WORKSPACE_KEY" "$REPO_KEY"
    fi

# Create a new container with one or more workspaces bound 1:1 (host path
# = container path). The rp wrapper translates CLI positional paths +
# --name into RP_NAME / RP_PATHS_RAW env vars consumed here. See ADR-0010.
create: _service-ensure
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    if container list -a -q | grep -qx "$CONT_NAME"; then
        echo "Container $CONT_NAME already exists for $WS_PRIMARY. Use 'rp destroy' first, or --name to create another."
        exit 1
    fi
    IMAGE_TAG=$( RP_SYSTEM_TAG={{image_tag}} {{justfile_directory()}}/scripts/build-project-image.sh "$WS_PRIMARY" )
    IMAGE_HASH=${IMAGE_TAG%:latest-rp}
    IMAGE_HASH=${IMAGE_HASH##*-}
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
    # Git stores outside the workspaces, e.g. a worktree's common dir
    # (ADR-0019). Bound 1:1; rp-init mounts :ro ones through rp-fuse.
    git_dirs_env=""
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        p=${entry%:ro}
        bind_args+=(-v "$p:$p")
        git_dirs_env="${git_dirs_env:+$git_dirs_env }$entry"
    done < <( {{justfile_directory()}}/scripts/resolve-git-dirs.sh "${ws_entries[@]}" )
    # Persistent volumes (ADR-0014, ADR-0024). Same mechanism as _ensure.
    volume_pairs=""
    while IFS=$'\t' read -r host_dir cont_mount vol_name; do
        [ -z "$host_dir" ] && continue
        bind_args+=(-v "$host_dir:$cont_mount")
        if [ -n "$volume_pairs" ]; then
            volume_pairs="${volume_pairs},"
        fi
        volume_pairs="${volume_pairs}${cont_mount}=${vol_name}"
    done < <( {{justfile_directory()}}/scripts/resolve-volumes.sh "$WS_PRIMARY" "$AGENT" "$WORKSPACE_KEY" "$REPO_KEY" "$USER_NAME" )
    vol_env=()
    if [ -n "$volume_pairs" ]; then
        vol_env+=(-e "RP_VOLUMES=$volume_pairs")
    fi
    extra_args=()
    if [ -n "$EXTRA_TSV" ]; then
        IFS=$'\t' read -r -a extra_args <<<"${EXTRA_TSV%$'\t'}"
    fi
    container create \
        --name "$CONT_NAME" \
        --cap-add SYS_ADMIN \
        -l "rp.host_path=$WS_PRIMARY" \
        -l "rp.name_explicit=$NAME_EXPLICIT" \
        -l "rp.image_hash=$IMAGE_HASH" \
        -l "rp.volume_key=$WORKSPACE_KEY" \
        -l "rp.agent=$AGENT" \
        -l rp.managed=true \
        $CONTAINER_ENV \
        $CREATE_FLAGS \
        -e "RP_WORKSPACE=$RP_WORKSPACE_ENV" \
        -e "RP_GIT_DIRS=$git_dirs_env" \
        "${vol_env[@]+${vol_env[@]}}" \
        "${bind_args[@]}" \
        ${extra_args[@]+"${extra_args[@]}"} \
        "$IMAGE_TAG"
    # Start so we can `container cp` host files into the running container
    # (Apple Container's cp requires state=running). See ADR-0015.
    container start "$CONT_NAME" > /dev/null
    {{justfile_directory()}}/scripts/seed-host-files.sh \
        "$WS_PRIMARY" "$AGENT" "$CONT_NAME" "$USER_NAME" "$WORKSPACE_KEY" "$REPO_KEY"
    echo "Container $CONT_NAME created. Workspaces: $RP_WORKSPACE_ENV (image $IMAGE_TAG${CREATE_FLAGS:+, $CREATE_FLAGS})"

# Start a stopped container
start: _service-ensure
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
    container exec -it -u "$USER_NAME" --workdir "$ws" "$CONT_NAME" "$script" ${args[@]+"${args[@]}"}

# Copy files from host to container
cp-to name src dest:
    container cp {{src}} {{name}}:{{dest}}

# Copy files from container to host
cp-from name src dest:
    container cp {{name}}:{{src}} {{dest}}

# Stop and remove a container and its workspace volumes (ADR-0025).
# Workspace files on the host, the shared image (ADR-0022) and the repo's
# memory (ADR-0024) stay. Volumes of a container from before ADR-0024 have
# no key label; they stay too, and `rp gc --legacy` removes them.
destroy:
    #!/usr/bin/env bash
    set -uo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    volume_key=$(container inspect "$CONT_NAME" 2>/dev/null | jq -r '.[0].configuration.labels["rp.volume_key"] // empty')
    container stop "$CONT_NAME" 2>/dev/null || true
    container delete "$CONT_NAME" || exit 1
    vol_root=${RP_VOLUMES_DIR:-$HOME/.local/share/robo-pen/volumes}
    if [[ "$volume_key" =~ ^[a-z0-9._-]+$ ]]; then
        rm -rf "$vol_root/workspaces/$volume_key"
        echo "Container $CONT_NAME and its workspace volumes removed. Workspace files on host untouched."
    else
        echo "Container $CONT_NAME removed. Workspace files on host untouched."
        if [ -d "$vol_root/$CONT_NAME" ]; then
            echo "Its pre-worktree volumes stay at $vol_root/$CONT_NAME ('rp gc --legacy' removes them)."
        fi
    fi

# Replace a container with one built from the current .rp/ inputs, keeping
# its name, workspaces and volumes (ADR-0022). The image is built before
# the old container is removed, so a failing build leaves it intact.
# A container from before ADR-0024 is migrated on the way: its volumes
# move to the workspace key, its auto-memory seeds the repo's (ADR-0025).
# RP_REBUILD=1 (rp recreate --rebuild) forces a fresh image build.
# Extra `container create` flags given after `--` at create are not kept.
recreate: _service-ensure
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$( {{justfile_directory()}}/scripts/resolve-recipe-ctx.sh "{{host_dir}}" )"
    info=$(container inspect "$CONT_NAME" 2>/dev/null) || { echo "rp: no container $CONT_NAME" >&2; exit 1; }
    workspaces=$(jq -r '.[0].configuration.initProcess.environment[] | select(startswith("RP_WORKSPACE=")) | sub("^RP_WORKSPACE="; "")' <<<"$info")
    explicit=$(jq -r '.[0].configuration.labels["rp.name_explicit"] // "0"' <<<"$info")
    [ -n "$workspaces" ] || { echo "rp: cannot read the workspaces of $CONT_NAME" >&2; exit 1; }
    primary=${workspaces%% *}
    primary=${primary%:ro}
    RP_SYSTEM_TAG={{image_tag}} {{justfile_directory()}}/scripts/build-project-image.sh "$primary" >/dev/null
    container stop "$CONT_NAME" >/dev/null 2>&1 || true
    container delete "$CONT_NAME" >/dev/null
    # Keys from the recorded workspace, as create will compute them; the
    # ctx's are from cwd, which differs under --name.
    . {{justfile_directory()}}/scripts/lib-identity.sh
    rp_git_info "$primary"
    repo_key=""
    [ -z "$RP_GIT_COMMON" ] || repo_key=$(rp_repo_key "$RP_GIT_COMMON")
    {{justfile_directory()}}/scripts/migrate-legacy-volumes.sh \
        "$primary" "$AGENT" "$CONT_NAME" "$(rp_workspace_key "$CONT_NAME" "$primary")" "$repo_key" "$USER_NAME" \
        || echo "rp: WARN volume migration failed; creating $CONT_NAME anyway" >&2
    export RP_NAME="$NAME" RP_NAME_EXPLICIT="$explicit" RP_PATHS_RAW="$(tr ' ' '\n' <<<"$workspaces")"
    unset RP_REBUILD RP_LOOKUP_ONLY RP_EXTRA_ARGS_RAW
    just --justfile {{justfile()}} create

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
