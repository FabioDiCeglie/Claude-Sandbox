#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT}/docker/docker-compose.yaml"

echo
echo "🛑  Stop claude-sandbox-shell"
echo

docker compose -f "${COMPOSE_FILE}" --profile sandbox down -v --remove-orphans
echo "  ✅  shell stopped"
