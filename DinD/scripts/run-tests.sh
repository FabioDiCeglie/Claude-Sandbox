#!/usr/bin/env bash
# Run inside claude-sandbox-cli — runs pytest in the app container.
set -euo pipefail

docker run --rm \
  -v /workspace:/workspace \
  -w /workspace \
  claude-sandbox-app:latest \
  bash -lc "uv sync --group dev && uv run pytest"
