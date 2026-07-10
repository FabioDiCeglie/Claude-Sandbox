#!/usr/bin/env bash
# Run inside claude-sandbox-dood-cli — builds the app image if needed, then runs pytest.
set -euo pipefail

PROXY_HOST="${HTTP_PROXY:-http://claude-sandbox-dood-proxy:3128}"

echo "Building app image..."
docker build -q -t claude-sandbox-dood-proxy-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace
echo "Build complete."

docker run --rm \
  --network sandbox-net \
  --env HTTP_PROXY="${PROXY_HOST}" \
  --env HTTPS_PROXY="${PROXY_HOST}" \
  --env NO_PROXY="localhost,127.0.0.1" \
  claude-sandbox-dood-proxy-app:latest \
  uv run pytest
