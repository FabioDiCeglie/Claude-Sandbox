#!/usr/bin/env bash
# Run inside claude-sandbox-cli — runs the FastAPI server in the app container.
set -euo pipefail

docker run --rm -p 8080:8080 claude-sandbox-app:latest uv run dind-app
