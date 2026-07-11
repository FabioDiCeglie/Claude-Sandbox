#!/usr/bin/env bash
# Run inside the Colima VM — builds the app image, then starts the server.
# The VM has its own Docker daemon; this never touches the host daemon.
# Docker image pulls go through Squid (proxy-aware daemon configuration).
set -euo pipefail

echo "Building app image..."
docker build -q -t claude-sandbox-colima-proxy-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace >/dev/null 2>&1
echo "Build complete."

docker run --rm \
  -p 8080:8080 \
  claude-sandbox-colima-proxy-app:latest \
  uv run colima-proxy-app
