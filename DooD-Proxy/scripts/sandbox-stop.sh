#!/usr/bin/env bash
set -euo pipefail

echo
echo "🛑  Stop DooD-Proxy sandbox"
echo

docker rm -f claude-sandbox-dood-cli 2>/dev/null \
  && echo "  ✅  CLI container removed" || true

leftover=$(docker ps -aq --filter ancestor=claude-sandbox-dood-proxy-app:latest 2>/dev/null || true)
if [[ -n "${leftover}" ]]; then
  echo "${leftover}" | xargs docker rm -f
  echo "  ✅  app container(s) removed"
fi

docker rm -f claude-sandbox-dood-socket-proxy 2>/dev/null \
  && echo "  ✅  socket-proxy removed" || true

docker rm -f claude-sandbox-dood-proxy 2>/dev/null \
  && echo "  ✅  Squid proxy removed" || true

docker network rm sandbox-net 2>/dev/null \
  && echo "  ✅  sandbox-net removed" || true

docker network rm proxy-egress 2>/dev/null \
  && echo "  ✅  proxy-egress removed" || true

echo "  DooD-Proxy sandbox stopped."
