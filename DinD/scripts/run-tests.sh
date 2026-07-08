#!/usr/bin/env bash
# Run inside claude-sandbox-cli — builds the app image if needed, then runs pytest.
set -euo pipefail

echo "Building app image..."
docker build -q -t claude-sandbox-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace > /dev/null
echo "Build complete."

docker run --rm claude-sandbox-app:latest uv run pytest
