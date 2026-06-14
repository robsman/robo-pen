# claude-container — default per-project image used when a workspace has no
# `.ccr/config.yaml` or `.ccr/Dockerfile`. Adds the standard Claude-friendly
# toolchain (Node, Python+uv, R, DuckDB, just, build-essential, Claude CLI)
# on top of ccr-base. Build it with `ccr build` after `ccr build-base`.

FROM ccr-base

USER root

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages (tools the default user-image expects) ──────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        apt-utils git curl \
        build-essential \
        python3 python3-dev python3-venv \
        r-base \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 22 via NodeSource ────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── DuckDB CLI (architecture-aware) ─────────────────────────────
ARG DUCKDB_VERSION=1.4.3
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${ARCH}.zip" -o /tmp/duckdb.zip \
    && apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/duckdb.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/duckdb \
    && rm /tmp/duckdb.zip \
    && apt-get purge -y unzip && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# ── just ─────────────────────────────────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# ── In-container Claude config (baked in for the default image only) ─
RUN mkdir -p /home/coder/.claude && chown -R coder:coder /home/coder/.claude
COPY --chown=coder:coder config/claude-settings.json /home/coder/.claude/settings.json
COPY --chown=coder:coder config/CLAUDE.md /home/coder/.claude/CLAUDE.md

USER coder
WORKDIR /home/coder

# ── uv (Python package manager) ─────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/home/coder/.local/bin:${PATH}"

# ── Claude Code CLI ──────────────────────────────────────────────
RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR /workspace
