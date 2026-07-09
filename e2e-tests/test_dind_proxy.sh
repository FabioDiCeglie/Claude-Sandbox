#!/usr/bin/env bash
# E2E test for the DinD-Proxy sandbox.
#
# Steps:
#   1. Start claude-sandbox-proxy-shell (privileged DinD container)
#   2. Wait for inner Docker daemon
#   3. ASSERT: inner daemon ID differs from host daemon ID
#   4. Create proxy-egress and sandbox-net (internal) networks
#   5. Build + start sandbox-proxy (Squid)
#   6. ASSERT: Squid is accepting connections on :3128
#   7. Build + start socket-proxy (Docker API filter)
#   8. ASSERT: socket-proxy is running
#   9. ASSERT: sandbox-net is --internal (no direct internet)
#  10. Build claude-sandbox-cli
#  11. Lock .env files
#  12. ASSERT: docker run --privileged is blocked by socket-proxy
#  13. ASSERT: run-tests.sh exits 0 inside the CLI container
#  14. Tear down (trap)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIND_PROXY_ROOT="${REPO_ROOT}/DinD-Proxy"
COMPOSE_FILE="${DIND_PROXY_ROOT}/docker/docker-compose.yaml"
SHELL_NAME="claude-sandbox-proxy-shell"
PROXY_NAME="sandbox-proxy"
PROXY_PORT="3128"
SOCKET_PROXY_NAME="socket-proxy"
SOCKET_PROXY_PORT="2375"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-120}"

PASS=0
FAIL=0

pass() { echo "  ✅  PASS — $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  FAIL — $*" >&2; FAIL=$((FAIL + 1)); }

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  echo
  echo "▶ Tearing down"
  docker compose -f "${COMPOSE_FILE}" --profile sandbox down -v --remove-orphans 2>/dev/null || true
  echo
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ "${FAIL}" -eq 0 ]] || exit 1
}
trap cleanup EXIT

# ── 1. Start shell ────────────────────────────────────────────────────────────
echo
echo "▶ Starting ${SHELL_NAME}"
docker compose -f "${COMPOSE_FILE}" --profile sandbox up -d shell --quiet-pull 2>/dev/null || \
  docker compose -f "${COMPOSE_FILE}" --profile sandbox up -d shell

echo "▶ Waiting for inner Docker daemon (up to ${MAX_WAIT_SECONDS}s)"
deadline=$((SECONDS + MAX_WAIT_SECONDS))
until docker exec "${SHELL_NAME}" docker info >/dev/null 2>&1; do
  (( SECONDS < deadline )) || { echo "  ❌  inner daemon timeout" >&2; exit 1; }
  sleep 2
done
echo "  inner daemon ready"

# ── 2. ASSERT: daemon isolation ───────────────────────────────────────────────
echo
echo "━━ Test: daemon isolation ━━"
host_id="$(docker info -f '{{.ID}}')"
inner_id="$(docker exec "${SHELL_NAME}" docker info -f '{{.ID}}')"
echo "  Host daemon ID    ${host_id}"
echo "  Inner daemon ID   ${inner_id}"

if [[ "${host_id}" != "${inner_id}" ]]; then
  pass "daemon IDs differ — inner daemon is isolated from host"
else
  fail "daemon IDs match (${host_id}) — inner daemon is NOT isolated"
fi

# ── 3. Create inner networks ──────────────────────────────────────────────────
echo
echo "▶ Creating inner networks"
docker exec "${SHELL_NAME}" docker network inspect proxy-egress >/dev/null 2>&1 \
  || docker exec "${SHELL_NAME}" docker network create proxy-egress
docker exec "${SHELL_NAME}" docker network inspect sandbox-net >/dev/null 2>&1 \
  || docker exec "${SHELL_NAME}" docker network create --internal sandbox-net

# ── 4. ASSERT: sandbox-net is internal ───────────────────────────────────────
echo
echo "━━ Test: sandbox-net is --internal ━━"
is_internal="$(docker exec "${SHELL_NAME}" \
  docker network inspect sandbox-net --format '{{.Internal}}')"
if [[ "${is_internal}" == "true" ]]; then
  pass "sandbox-net is internal — no direct internet for containers"
else
  fail "sandbox-net is NOT internal — containers can bypass Squid"
fi

# ── 5. Build + start Squid ────────────────────────────────────────────────────
echo
echo "▶ Building sandbox-proxy (Squid)"
docker exec "${SHELL_NAME}" docker build -q \
  -t sandbox-proxy:latest \
  -f /workspace/docker/Dockerfile.squid \
  /workspace/docker >/dev/null
echo "  done"

docker exec "${SHELL_NAME}" docker rm -f "${PROXY_NAME}" >/dev/null 2>&1 || true
docker exec "${SHELL_NAME}" docker run -d \
  --name "${PROXY_NAME}" \
  --network proxy-egress \
  --restart unless-stopped \
  sandbox-proxy:latest
docker exec "${SHELL_NAME}" docker network connect sandbox-net "${PROXY_NAME}"

# ── 6. ASSERT: Squid accepts connections ──────────────────────────────────────
echo
echo "━━ Test: Squid is accepting connections ━━"
deadline=$((SECONDS + 30))
squid_ready=false
until docker exec "${SHELL_NAME}" \
    docker exec "${PROXY_NAME}" sh -c "nc -z localhost ${PROXY_PORT}" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then break; fi
  sleep 1
done
if docker exec "${SHELL_NAME}" \
    docker exec "${PROXY_NAME}" sh -c "nc -z localhost ${PROXY_PORT}" >/dev/null 2>&1; then
  pass "Squid is accepting connections on :${PROXY_PORT}"
else
  fail "Squid did not become ready within 30s on :${PROXY_PORT}"
fi

# ── 7. Build + start socket-proxy ────────────────────────────────────────────
echo
echo "▶ Building socket-proxy"
docker exec "${SHELL_NAME}" docker build -q \
  -t socket-proxy:latest \
  -f /workspace/docker/Dockerfile.socket-proxy \
  /workspace/docker >/dev/null
echo "  done"

docker exec "${SHELL_NAME}" docker rm -f "${SOCKET_PROXY_NAME}" >/dev/null 2>&1 || true
docker exec "${SHELL_NAME}" docker run -d \
  --name "${SOCKET_PROXY_NAME}" \
  --network sandbox-net \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --restart unless-stopped \
  socket-proxy:latest

# ── 8. ASSERT: socket-proxy is running ───────────────────────────────────────
echo
echo "━━ Test: socket-proxy is running ━━"
sp_running="$(docker exec "${SHELL_NAME}" \
  docker inspect --format '{{.State.Running}}' "${SOCKET_PROXY_NAME}" 2>/dev/null || echo false)"
if [[ "${sp_running}" == "true" ]]; then
  pass "socket-proxy is running on sandbox-net:${SOCKET_PROXY_PORT}"
else
  fail "socket-proxy is not running"
fi

# ── 9. Build CLI image ────────────────────────────────────────────────────────
echo
echo "▶ Building claude-sandbox-cli (this takes a minute)"
docker exec "${SHELL_NAME}" docker build -q \
  -t claude-sandbox-cli:latest \
  -f /workspace/docker/Dockerfile.claude-cli \
  /workspace/docker >/dev/null
echo "  done"

# ── 10. Lock .env files ───────────────────────────────────────────────────────
echo
echo "▶ Locking .env files"
docker exec "${SHELL_NAME}" sh -c '
  find /workspace -type f \( \
    -name ".env" -o -name ".env.*" -o -name "*.env" \
    -o -name "secrets.*" -o -name "credentials.*" \
  \) -print0 | xargs -0 -r chmod 000
'
locked=$(docker exec "${SHELL_NAME}" sh -c '
  find /workspace -type f \( \
    -name ".env" -o -name ".env.*" -o -name "*.env" \
    -o -name "secrets.*" -o -name "credentials.*" \
  \) | wc -l | tr -d " "
')
echo "  ${locked} file(s) locked"

# ── 11. ASSERT: socket-proxy blocks --privileged ──────────────────────────────
echo
echo "━━ Test: socket-proxy blocks --privileged containers ━━"
if docker exec "${SHELL_NAME}" docker run --rm \
  --user nobody \
  --network sandbox-net \
  --env HTTP_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env HTTPS_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env NO_PROXY="localhost,127.0.0.1,${SOCKET_PROXY_NAME}" \
  --env DOCKER_HOST="tcp://${SOCKET_PROXY_NAME}:${SOCKET_PROXY_PORT}" \
  -v /workspace:/workspace \
  -w /workspace \
  claude-sandbox-cli:latest \
  docker run --rm --privileged alpine echo ok >/dev/null 2>&1; then
  fail "socket-proxy allowed --privileged — Docker API filter is not working"
else
  pass "socket-proxy blocked --privileged container (got non-zero exit)"
fi

# ── 12. ASSERT: tests pass inside sandbox ────────────────────────────────────
echo
echo "━━ Test: run-tests.sh inside sandbox ━━"
if docker exec "${SHELL_NAME}" docker run --rm \
  --user nobody \
  --network sandbox-net \
  --env HTTP_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env HTTPS_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env NO_PROXY="localhost,127.0.0.1,${SOCKET_PROXY_NAME}" \
  --env DOCKER_HOST="tcp://${SOCKET_PROXY_NAME}:${SOCKET_PROXY_PORT}" \
  -v /workspace:/workspace \
  -w /workspace \
  claude-sandbox-cli:latest \
  bash -c './scripts/run-tests.sh'; then
  pass "run-tests.sh exited 0"
else
  fail "run-tests.sh exited non-zero"
fi
