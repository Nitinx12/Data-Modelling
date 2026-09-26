# syntax=docker/dockerfile:1
FROM python:3.13-slim-bookworm

LABEL org.opencontainers.image.title="data-modelling-pipeline" \
      org.opencontainers.image.description="MongoDB to PostgreSQL Kimball warehouse pipeline (staging -> models -> quality -> GX)" \
      org.opencontainers.image.source="https://github.com/Nitinx12/Data-Modelling" \
      org.opencontainers.image.version="0.1.0"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_SYSTEM_PYTHON=1 \
    PYTHONUTF8=1

# System deps: curl for uv install, make/bash for Makefile targets
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    make \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Astral)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Non-root runtime user. Writable uv cache plus /app/.venv and /app/logs
# (anonymous volumes in compose inherit this ownership on first boot).
RUN useradd --create-home --uid 1000 appuser \
    && mkdir -p /app/.venv /app/logs /home/appuser/.cache \
    && chown -R appuser:appuser /app /home/appuser
ENV HOME=/home/appuser

WORKDIR /app

# Copy dependency manifests first for layer caching
COPY pyproject.toml uv.lock README.md ./

# Copy source so uv can resolve project (utils, scripts, etc.)
COPY utils ./utils
COPY scripts ./scripts
COPY models ./models
COPY sql ./sql
COPY gx ./gx
COPY tests ./tests
COPY orchestration ./orchestration
COPY main.py ./

# Install deps — the dev group is required at runtime: great-expectations
# powers the --strict quality gate in `make pipeline` and dagster serves
# the asset DAG in the dagster service.
RUN uv sync --frozen --group dev \
    && chown -R appuser:appuser /app

# Copy remaining project files
COPY --chown=appuser:appuser . .

USER appuser

# Smoke check: heaviest runtime deps import without DB connections.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import dagster, great_expectations, sqlalchemy, pymongo" || exit 1

# Default command runs the full ELT pipeline (staging -> models -> quality -> GX)
# Overridden by docker-compose `command` if needed
CMD ["uv", "run", "python", "scripts/python/main.py"]
