#!/usr/bin/env bash
set -euo pipefail

echo
echo "🛑  Stop DooD sandbox"
echo

docker rm -f claude-sandbox-dood-cli 2>/dev/null && echo "  ✅  CLI container removed" || true

leftover=$(docker ps -aq --filter ancestor=claude-sandbox-dood-app:latest 2>/dev/null || true)
if [[ -n "${leftover}" ]]; then
  echo "${leftover}" | xargs docker rm -f
  echo "  ✅  app container(s) removed"
fi

echo "  DooD sandbox stopped."
