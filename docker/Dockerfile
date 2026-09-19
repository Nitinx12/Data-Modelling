# syntax=docker/dockerfile:1
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_SYSTEM_PYTHON=1 \
    PYTHONUTF8=1

# System deps: curl for uv install, make/bash for Makefile (optional)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    make \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Astral)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

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

# Install deps — include dev group so dagster/gx/ruff are available in demo
RUN uv sync --frozen --group dev

# Copy remaining project files
COPY . .

# Default command runs the full ELT pipeline (staging -> models -> quality -> GX)
# Overridden by docker-compose `command` if needed
CMD ["uv", "run", "python", "scripts/python/main.py"]
