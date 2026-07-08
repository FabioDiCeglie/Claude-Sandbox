#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT}/docker/docker-compose.yaml"

echo
echo "🛑  Stop DinD-Proxy sandbox"
echo

# The shell container's volume holds the inner Docker state (images, networks,
# containers). Bringing it down with -v wipes everything cleanly.
docker compose -f "${COMPOSE_FILE}" --profile sandbox down -v --remove-orphans
echo "  ✅  shell stopped and inner containers cleaned up"
