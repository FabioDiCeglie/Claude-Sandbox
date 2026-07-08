#!/usr/bin/env bash
# Start the DinD-Proxy sandbox.
#
# Network topology inside the inner daemon:
#
#   proxy-egress  (normal bridge — internet-accessible)
#     └── sandbox-proxy (Squid)
#
#   sandbox-net   (--internal — no direct internet)
#     ├── sandbox-proxy  (Squid HTTP egress filter)
#     ├── socket-proxy   (Docker API filter — blocks --privileged etc.)
#     └── claude-sandbox-cli
#         └── claude-sandbox-app (spawned by scripts inside cli)
#
# Two proxies, two layers:
#   Squid       → controls which websites/APIs are reachable
#   socket-proxy → controls which Docker operations are allowed
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT}/docker/docker-compose.yaml"
SHELL_NAME="claude-sandbox-proxy-shell"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-90}"
PROXY_NAME="sandbox-proxy"
PROXY_PORT="3128"
SOCKET_PROXY_NAME="socket-proxy"
SOCKET_PROXY_PORT="2375"

cd "${ROOT}"

echo
echo "🚀  Start DinD + Proxy sandbox"
echo

# ── 1. Start shell (inner Docker daemon) ──────────────────────────────────────
echo "▶ Starting shell container"
docker compose -f "${COMPOSE_FILE}" --profile sandbox up -d shell
echo "  ✅  ${SHELL_NAME} running"

echo
echo "▶ Waiting for inner Docker daemon"
deadline=$((SECONDS + MAX_WAIT_SECONDS))
until docker exec "${SHELL_NAME}" docker info >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "  ❌  inner daemon not ready after ${MAX_WAIT_SECONDS}s" >&2
    exit 1
  fi
  sleep 1
done
echo "  ✅  inner daemon ready"

# ── 2. Daemon isolation check ─────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Isolation check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
host_id="$(docker info -f '{{.ID}}')"
inner_id="$(docker exec "${SHELL_NAME}" docker info -f '{{.ID}}')"
echo "  Host daemon ID     ${host_id}"
echo "  Shell daemon ID    ${inner_id}"
if [[ "${host_id}" == "${inner_id}" ]]; then
  echo "  ⚠️  Same ID — daemons are not isolated" >&2
  exit 1
fi
echo "  ✅  Different IDs — shell has its own Docker daemon"

# ── 3. Create networks inside the inner daemon ────────────────────────────────
echo
echo "▶ Creating inner networks"

# proxy-egress: normal bridge network — only the proxy container lives here
# so it can reach the internet.
docker exec "${SHELL_NAME}" docker network inspect proxy-egress >/dev/null 2>&1 \
  || docker exec "${SHELL_NAME}" docker network create proxy-egress
echo "  ✅  proxy-egress (internet-accessible)"

# sandbox-net: --internal network — no container can reach the internet
# directly; must go through the proxy.
docker exec "${SHELL_NAME}" docker network inspect sandbox-net >/dev/null 2>&1 \
  || docker exec "${SHELL_NAME}" docker network create --internal sandbox-net
echo "  ✅  sandbox-net (internal — no direct internet)"

# ── 4. Build proxy image inside the inner daemon ──────────────────────────────
echo
echo "▶ Building sandbox-proxy (Squid) inside shell"
docker exec "${SHELL_NAME}" docker build \
  -t sandbox-proxy:latest \
  -f /workspace/docker/Dockerfile.squid \
  /workspace/docker
echo "  ✅  sandbox-proxy:latest"

# ── 5. Start the proxy container ──────────────────────────────────────────────
echo
echo "▶ Starting ${PROXY_NAME}"

# Remove any stale container from a previous run
docker exec "${SHELL_NAME}" docker rm -f "${PROXY_NAME}" >/dev/null 2>&1 || true

# Start proxy on proxy-egress only (it gets internet access from here)
docker exec "${SHELL_NAME}" docker run -d \
  --name "${PROXY_NAME}" \
  --network proxy-egress \
  --restart unless-stopped \
  sandbox-proxy:latest

# Also attach the proxy to sandbox-net so CLI/app can reach it
docker exec "${SHELL_NAME}" docker network connect sandbox-net "${PROXY_NAME}"
echo "  ✅  ${PROXY_NAME} running on proxy-egress + sandbox-net"

# ── 6. Wait for Squid to accept connections ───────────────────────────────────
echo
echo "▶ Waiting for Squid to accept connections"
deadline=$((SECONDS + 30))
until docker exec "${SHELL_NAME}" \
      docker exec "${PROXY_NAME}" \
      sh -c "nc -z localhost ${PROXY_PORT}" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "  ❌  Squid not ready after 30s" >&2
    exit 1
  fi
  sleep 1
done
echo "  ✅  Squid ready on :${PROXY_PORT}"

# ── 7. Build + start socket proxy ────────────────────────────────────────────
echo
echo "▶ Building socket-proxy (Docker API filter) inside shell"
docker exec "${SHELL_NAME}" docker build \
  -t socket-proxy:latest \
  -f /workspace/docker/Dockerfile.socket-proxy \
  /workspace/docker
echo "  ✅  socket-proxy:latest"

echo
echo "▶ Starting ${SOCKET_PROXY_NAME}"
docker exec "${SHELL_NAME}" docker rm -f "${SOCKET_PROXY_NAME}" >/dev/null 2>&1 || true

docker exec "${SHELL_NAME}" docker run -d \
  --name "${SOCKET_PROXY_NAME}" \
  --network sandbox-net \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --restart unless-stopped \
  socket-proxy:latest
echo "  ✅  ${SOCKET_PROXY_NAME} running on sandbox-net:${SOCKET_PROXY_PORT}"

# ── 8. Build CLI image inside the inner daemon ────────────────────────────────
echo
echo "▶ Building claude-sandbox-cli inside shell"
docker exec "${SHELL_NAME}" docker build \
  -t claude-sandbox-cli:latest \
  -f /workspace/docker/Dockerfile.claude-cli \
  /workspace/docker
echo "  ✅  claude-sandbox-cli:latest"

# ── 9. Summary + drop into CLI ───────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Sandbox ready — entering CLI"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  HTTP/HTTPS  → Squid (domain allowlist)"
echo "  Docker API  → socket-proxy (blocks --privileged, dangerous caps)"
echo "  Run \`claude\` when ready. Stop with: ./scripts/sandbox-stop.sh"
echo

exec docker exec -it "${SHELL_NAME}" docker run --rm -it \
  --network sandbox-net \
  --env HTTP_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env HTTPS_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env NO_PROXY="localhost,127.0.0.1,${SOCKET_PROXY_NAME}" \
  --env DOCKER_HOST="tcp://${SOCKET_PROXY_NAME}:${SOCKET_PROXY_PORT}" \
  -v /workspace:/workspace \
  -w /workspace \
  claude-sandbox-cli:latest \
  bash
