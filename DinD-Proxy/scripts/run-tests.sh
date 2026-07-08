#!/usr/bin/env bash
# Run inside claude-sandbox-cli — builds the app image if needed, then runs pytest.
set -euo pipefail

PROXY_HOST="${HTTP_PROXY:-http://sandbox-proxy:3128}"

docker build -t claude-sandbox-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace

docker run --rm \
  --network sandbox-net \
  --env HTTP_PROXY="${PROXY_HOST}" \
  --env HTTPS_PROXY="${PROXY_HOST}" \
  --env NO_PROXY="localhost,127.0.0.1" \
  claude-sandbox-app:latest \
  uv run pytest
