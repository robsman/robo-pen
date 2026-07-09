# robo-pen-default — default per-project base image. Used when a workspace
# has no `.rp/Dockerfile` and no `.rp/config.yaml` `image:` / `build:` line.
# Deliberately minimal and language-agnostic: git + curl + a compiler
# toolchain, no language runtime baked in. Agent profiles are installed by
# the rp overlay at create time, so the same default image works for
# claude-code, opencode, etc. Projects that want a language runtime (Node,
# Python, R, ...) add it via their own `.rp/Dockerfile` or `image:` —
# see .rp.example/Dockerfile.full-toolchain for the Node/Python+uv/R/DuckDB/
# just combo this image used to carry for everyone.

FROM rp-base

USER root

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages (language-agnostic floor) ────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        apt-utils git curl \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# ── Image-toolchain fragment describing what's installed above. The ──
# ── overlay concatenates it with 00-container.md + the agent profile  ──
# ── into the agent's instruction file.                                ──
COPY config/10-toolchain-default.md /etc/rp/instructions/10-toolchain.md

USER coder
WORKDIR /home/coder
