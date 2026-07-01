#!/usr/bin/env bash
# Run inside claude-sandbox-cli — runs the FastAPI server in the app container.
set -euo pipefail

docker run --rm -p 8080:8080 \
  -v /workspace:/workspace \
  -w /workspace \
  claude-sandbox-app:latest \
  bash -lc "uv sync --group dev && uv run dind-app"
