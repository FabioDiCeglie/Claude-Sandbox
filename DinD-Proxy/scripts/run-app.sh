#!/usr/bin/env bash
# Run inside claude-sandbox-cli — builds the app image if needed, then starts the server.
set -euo pipefail

PROXY_HOST="${HTTP_PROXY:-http://sandbox-proxy:3128}"

echo "Building app image..."
docker build -q -t claude-sandbox-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace >/dev/null 2>&1
echo "Build complete."

docker run --rm \
  --network sandbox-net \
  --env HTTP_PROXY="${PROXY_HOST}" \
  --env HTTPS_PROXY="${PROXY_HOST}" \
  --env NO_PROXY="localhost,127.0.0.1" \
  -p 8080:8080 \
  claude-sandbox-app:latest \
  uv run dind-app
