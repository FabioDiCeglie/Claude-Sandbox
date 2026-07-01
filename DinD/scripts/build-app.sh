#!/usr/bin/env bash
# Run inside claude-sandbox-cli — builds the app image on the shell's Docker daemon.
set -euo pipefail

docker build -t claude-sandbox-app:latest \
  -f /workspace/docker/Dockerfile \
  /workspace

echo "✅  claude-sandbox-app:latest"
