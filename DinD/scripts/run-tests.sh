#!/usr/bin/env bash
# Run inside claude-sandbox-cli — runs pytest in the app container.
set -euo pipefail

docker run --rm claude-sandbox-app:latest uv run pytest
