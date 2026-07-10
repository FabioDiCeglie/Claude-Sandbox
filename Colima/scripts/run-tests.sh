#!/usr/bin/env bash
# Run inside the Colima VM — builds the app image, then runs pytest.
# The VM has its own Docker daemon; this never touches the host daemon.
set -euo pipefail

echo "Building app image..."
docker build -q -t claude-sandbox-colima-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace
echo "Build complete."

docker run --rm \
  claude-sandbox-colima-app:latest \
  uv run pytest
