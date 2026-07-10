#!/usr/bin/env bash
# Run inside claude-sandbox-dood-cli — builds the app image, then starts the server.
set -euo pipefail

echo "Building app image..."
docker build -q -t claude-sandbox-dood-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace
echo "Build complete."

docker run --rm -p 8080:8080 claude-sandbox-dood-app:latest uv run dood-app
