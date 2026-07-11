#!/usr/bin/env bash
# Run inside the Colima VM — builds the app image, then runs pytest.
# The VM has its own Docker daemon; this never touches the host daemon.
# Docker image pulls go through Squid (proxy-aware daemon configuration).
set -euo pipefail

echo "Building app image..."
docker build -q -t claude-sandbox-colima-proxy-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace
echo "Build complete."

docker run --rm \
  claude-sandbox-colima-proxy-app:latest \
  uv run pytest
