#!/usr/bin/env bash
# Run inside claude-sandbox-cli — builds the app image if needed, then runs pytest.
set -euo pipefail

docker build -t claude-sandbox-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace

docker run --rm claude-sandbox-app:latest uv run pytest
