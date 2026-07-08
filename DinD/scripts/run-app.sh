#!/usr/bin/env bash
# Run inside claude-sandbox-cli — builds the app image if needed, then starts the server.
set -euo pipefail

echo "Building app image..."
DOCKER_BUILDKIT=1 docker build --progress=quiet \
  -t claude-sandbox-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace
echo "Build complete."

docker run --rm -p 8080:8080 claude-sandbox-app:latest uv run dind-app
