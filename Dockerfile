# robo-pen-default — default per-project base image. Used when a workspace
# has no `.rp/Dockerfile` and no `.rp/config.yaml` `image:` / `build:` line.
# Carries the toolchain (Node, Python+uv, R, DuckDB, just, build-essential)
# but NO agent — agent profiles are installed by the rp overlay at create
# time, so the same default image works for claude-code, opencode, etc.

FROM rp-base

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
# `unzip` stays installed after use: r-base-core Depends on it, so
# purging it here used to cascade-remove R (r-base, r-base-core, every
# r-cran-* package) via autoremove with no build error to flag it.
ARG DUCKDB_VERSION=1.4.3
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${ARCH}.zip" -o /tmp/duckdb.zip \
    && apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/duckdb.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/duckdb \
    && rm /tmp/duckdb.zip \
    && rm -rf /var/lib/apt/lists/*

# ── just ─────────────────────────────────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# ── Image-toolchain fragment describing what's installed above. The ──
# ── overlay concatenates it with 00-container.md + the agent profile  ──
# ── into the agent's instruction file.                                ──
COPY config/10-toolchain-default.md /etc/rp/instructions/10-toolchain.md

USER coder
WORKDIR /home/coder

# ── uv (Python package manager) ─────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/home/coder/.local/bin:${PATH}"

WORKDIR /home/coder
