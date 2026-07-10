#!/usr/bin/env bash
# Start the DooD-Proxy sandbox.
#
# Network topology on the HOST daemon (no privileged shell needed):
#
#   proxy-egress  (normal bridge — internet-accessible)
#     └── claude-sandbox-dood-proxy (Squid)
#
#   sandbox-net   (--internal — no direct internet)
#     ├── claude-sandbox-dood-proxy        (Squid HTTP egress filter)
#     ├── claude-sandbox-dood-socket-proxy (Docker API filter — blocks --privileged etc.)
#     └── claude-sandbox-dood-cli
#         └── claude-sandbox-dood-proxy-app (spawned by scripts inside cli)
#
# Two proxies, two layers:
#   Squid        → controls which websites/APIs are reachable
#   socket-proxy → controls which Docker operations are allowed
#
# Unlike DinD-Proxy there is no privileged shell container and no nested daemon.
# All containers run on the host daemon directly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_NAME="claude-sandbox-dood-cli"
PROXY_NAME="claude-sandbox-dood-proxy"
SOCKET_PROXY_NAME="claude-sandbox-dood-socket-proxy"
PROXY_PORT="3128"
SOCKET_PROXY_PORT="2375"

echo
echo "🚀  Start DooD + Proxy sandbox"
echo

# ── 1. Create host networks ────────────────────────────────────────────────────
echo "▶ Creating networks"

docker network inspect proxy-egress >/dev/null 2>&1 \
  || docker network create proxy-egress
echo "  ✅  proxy-egress (internet-accessible)"

docker network inspect sandbox-net >/dev/null 2>&1 \
  || docker network create --internal sandbox-net
echo "  ✅  sandbox-net (internal — no direct internet)"

# ── 2. Build + start Squid ────────────────────────────────────────────────────
echo
echo "▶ Building ${PROXY_NAME} (Squid)"
docker build -q \
  -t sandbox-proxy:latest \
  -f "${ROOT}/docker/Dockerfile.squid" \
  "${ROOT}/docker" >/dev/null 2>&1
echo "  ✅  sandbox-proxy:latest"

echo
echo "▶ Starting ${PROXY_NAME}"
docker rm -f "${PROXY_NAME}" >/dev/null 2>&1 || true
docker run -d \
  --name "${PROXY_NAME}" \
  --network proxy-egress \
  --restart unless-stopped \
  sandbox-proxy:latest
docker network connect sandbox-net "${PROXY_NAME}"
echo "  ✅  ${PROXY_NAME} on proxy-egress + sandbox-net"

# ── 3. Wait for Squid ─────────────────────────────────────────────────────────
echo
echo "▶ Waiting for Squid to accept connections"
deadline=$((SECONDS + 30))
until docker exec "${PROXY_NAME}" \
      sh -c "nc -z localhost ${PROXY_PORT}" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "  ❌  Squid not ready after 30s" >&2
    exit 1
  fi
  sleep 1
done
echo "  ✅  Squid ready on :${PROXY_PORT}"

# ── 4. Build + start socket-proxy ─────────────────────────────────────────────
echo
echo "▶ Building socket-proxy (Docker API filter)"
docker build -q \
  -t socket-proxy:latest \
  -f "${ROOT}/docker/Dockerfile.socket-proxy" \
  "${ROOT}/docker" >/dev/null 2>&1
echo "  ✅  socket-proxy:latest"

echo
echo "▶ Starting ${SOCKET_PROXY_NAME}"
docker rm -f "${SOCKET_PROXY_NAME}" >/dev/null 2>&1 || true
docker run -d \
  --name "${SOCKET_PROXY_NAME}" \
  --network sandbox-net \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --restart unless-stopped \
  socket-proxy:latest
echo "  ✅  ${SOCKET_PROXY_NAME} on sandbox-net:${SOCKET_PROXY_PORT}"

# ── 5. Build CLI image ────────────────────────────────────────────────────────
echo
echo "▶ Building claude-sandbox-dood-cli"
docker build -q \
  -t claude-sandbox-dood-cli:latest \
  -f "${ROOT}/docker/Dockerfile.claude-cli" \
  "${ROOT}/docker" >/dev/null 2>&1
echo "  ✅  claude-sandbox-dood-cli:latest"

# ── 6. Summary ────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Sandbox ready — entering CLI"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  HTTP/HTTPS  → Squid (domain allowlist)"
echo "  Docker API  → socket-proxy (blocks --privileged, dangerous caps)"
echo "  Run \`claude\` when ready. Stop with: ./scripts/sandbox-stop.sh"
echo

# ── 7. Lock .env files ────────────────────────────────────────────────────────
echo "▶ Locking .env files in workspace"
find "${ROOT}" -type f \( \
  -name ".env" -o -name ".env.*" -o -name "*.env" \
  -o -name "secrets.*" -o -name "credentials.*" \
\) -print0 | xargs -0 -r chmod 000 2>/dev/null || true
locked=$(find "${ROOT}" -type f \( \
  -name ".env" -o -name ".env.*" -o -name "*.env" \
  -o -name "secrets.*" -o -name "credentials.*" \
\) | wc -l | tr -d " ")
echo "  ✅  ${locked} secret file(s) locked (chmod 000)"
echo

# ── 8. Enter CLI ──────────────────────────────────────────────────────────────
echo "▶ Entering claude-sandbox-dood-cli"
echo

docker rm -f "${CLI_NAME}" >/dev/null 2>&1 || true

# Run as 'nobody' (uid 65534) so chmod 000 locks are effective.
# CLI uses DOCKER_HOST to talk to socket-proxy — never touches the raw host socket.
# HTTP/HTTPS traffic is forced through Squid via the internal sandbox-net.
exec docker run --rm -it \
  --name "${CLI_NAME}" \
  --user nobody \
  --network sandbox-net \
  --env HTTP_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env HTTPS_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env NO_PROXY="localhost,127.0.0.1,${SOCKET_PROXY_NAME}" \
  --env DOCKER_HOST="tcp://${SOCKET_PROXY_NAME}:${SOCKET_PROXY_PORT}" \
  -v "${ROOT}:/workspace" \
  -w /workspace \
  claude-sandbox-dood-cli:latest \
  bash
