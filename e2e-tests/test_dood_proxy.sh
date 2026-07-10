#!/usr/bin/env bash
# E2E test for the DooD-Proxy sandbox.
#
# Steps:
#   1. Create proxy-egress and sandbox-net (internal) networks on host daemon
#   2. ASSERT: sandbox-net is --internal
#   3. Build + start sandbox-proxy (Squid)
#   4. ASSERT: Squid is accepting connections on :3128
#   5. Build + start socket-proxy (Docker API filter)
#   6. ASSERT: socket-proxy is running
#   7. Build claude-sandbox-dood-cli
#   8. Lock .env files
#   9. ASSERT: docker run --privileged is blocked by socket-proxy
#  10. ASSERT: Squid blocks non-allowlisted domain (curl to example.com)
#  11. ASSERT: run-tests.sh exits 0 inside the CLI container
#  12. Tear down (trap)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOOD_PROXY_ROOT="${REPO_ROOT}/DooD-Proxy"
PROXY_NAME="claude-sandbox-dood-proxy"
SOCKET_PROXY_NAME="claude-sandbox-dood-socket-proxy"
CLI_NAME="claude-sandbox-dood-cli"
PROXY_PORT="3128"
SOCKET_PROXY_PORT="2375"

PASS=0
FAIL=0

pass() { echo "  ✅  PASS — $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  FAIL — $*" >&2; FAIL=$((FAIL + 1)); }

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  echo
  echo "▶ Tearing down"
  docker rm -f "${CLI_NAME}" 2>/dev/null || true
  leftover=$(docker ps -aq --filter ancestor=claude-sandbox-dood-proxy-app:latest 2>/dev/null || true)
  [[ -n "${leftover}" ]] && echo "${leftover}" | xargs docker rm -f 2>/dev/null || true
  docker rm -f "${SOCKET_PROXY_NAME}" 2>/dev/null || true
  docker rm -f "${PROXY_NAME}" 2>/dev/null || true
  docker network rm sandbox-net 2>/dev/null || true
  docker network rm proxy-egress 2>/dev/null || true
  echo
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ "${FAIL}" -eq 0 ]] || exit 1
}
trap cleanup EXIT

# ── 1. Create networks ────────────────────────────────────────────────────────
echo
echo "▶ Creating networks"
docker network inspect proxy-egress >/dev/null 2>&1 \
  || docker network create proxy-egress
docker network inspect sandbox-net >/dev/null 2>&1 \
  || docker network create --internal sandbox-net

# ── 2. ASSERT: sandbox-net is internal ───────────────────────────────────────
echo
echo "━━ Test: sandbox-net is --internal ━━"
is_internal="$(docker network inspect sandbox-net --format '{{.Internal}}')"
if [[ "${is_internal}" == "true" ]]; then
  pass "sandbox-net is internal — no direct internet for containers"
else
  fail "sandbox-net is NOT internal — containers can bypass Squid"
fi

# ── 3. Build + start Squid ────────────────────────────────────────────────────
echo
echo "▶ Building sandbox-proxy (Squid)"
docker build -q \
  -t sandbox-proxy:latest \
  -f "${DOOD_PROXY_ROOT}/docker/Dockerfile.squid" \
  "${DOOD_PROXY_ROOT}/docker" >/dev/null
echo "  done"

docker rm -f "${PROXY_NAME}" >/dev/null 2>&1 || true
docker run -d \
  --name "${PROXY_NAME}" \
  --network proxy-egress \
  --restart unless-stopped \
  sandbox-proxy:latest
docker network connect sandbox-net "${PROXY_NAME}"

# ── 4. ASSERT: Squid accepts connections ──────────────────────────────────────
echo
echo "━━ Test: Squid is accepting connections ━━"
deadline=$((SECONDS + 30))
until docker exec "${PROXY_NAME}" sh -c "nc -z localhost ${PROXY_PORT}" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then break; fi
  sleep 1
done
if docker exec "${PROXY_NAME}" sh -c "nc -z localhost ${PROXY_PORT}" >/dev/null 2>&1; then
  pass "Squid is accepting connections on :${PROXY_PORT}"
else
  fail "Squid did not become ready within 30s on :${PROXY_PORT}"
fi

# ── 5. Build + start socket-proxy ─────────────────────────────────────────────
echo
echo "▶ Building socket-proxy (Docker API filter)"
docker build -q \
  -t socket-proxy:latest \
  -f "${DOOD_PROXY_ROOT}/docker/Dockerfile.socket-proxy" \
  "${DOOD_PROXY_ROOT}/docker" >/dev/null
echo "  done"

docker rm -f "${SOCKET_PROXY_NAME}" >/dev/null 2>&1 || true
docker run -d \
  --name "${SOCKET_PROXY_NAME}" \
  --network sandbox-net \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --restart unless-stopped \
  socket-proxy:latest

# ── 6. ASSERT: socket-proxy is running ───────────────────────────────────────
echo
echo "━━ Test: socket-proxy is running ━━"
sp_running="$(docker inspect --format '{{.State.Running}}' "${SOCKET_PROXY_NAME}" 2>/dev/null || echo false)"
if [[ "${sp_running}" == "true" ]]; then
  pass "socket-proxy is running on sandbox-net:${SOCKET_PROXY_PORT}"
else
  fail "socket-proxy is not running"
fi

# ── 7. Build CLI image ────────────────────────────────────────────────────────
echo
echo "▶ Building claude-sandbox-dood-cli (this takes a minute)"
docker build -q \
  -t claude-sandbox-dood-cli:latest \
  -f "${DOOD_PROXY_ROOT}/docker/Dockerfile.claude-cli" \
  "${DOOD_PROXY_ROOT}/docker" >/dev/null
echo "  done"

# ── 8. Lock .env files ────────────────────────────────────────────────────────
echo
echo "▶ Locking .env files"
find "${DOOD_PROXY_ROOT}" -type f \( \
  -name ".env" -o -name ".env.*" -o -name "*.env" \
  -o -name "secrets.*" -o -name "credentials.*" \
\) -print0 | xargs -0 -r chmod 000 2>/dev/null || true
locked=$(find "${DOOD_PROXY_ROOT}" -type f \( \
  -name ".env" -o -name ".env.*" -o -name "*.env" \
  -o -name "secrets.*" -o -name "credentials.*" \
\) | wc -l | tr -d " ")
echo "  ${locked} file(s) locked"

# ── 9. ASSERT: socket-proxy blocks --privileged ───────────────────────────────
echo
echo "━━ Test: socket-proxy blocks --privileged containers ━━"
if docker run --rm \
  --user nobody \
  --network sandbox-net \
  --env HTTP_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env HTTPS_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env NO_PROXY="localhost,127.0.0.1,${SOCKET_PROXY_NAME}" \
  --env DOCKER_HOST="tcp://${SOCKET_PROXY_NAME}:${SOCKET_PROXY_PORT}" \
  -v "${DOOD_PROXY_ROOT}:/workspace" \
  -w /workspace \
  claude-sandbox-dood-cli:latest \
  docker run --rm --privileged alpine echo ok >/dev/null 2>&1; then
  fail "socket-proxy allowed --privileged — Docker API filter is not working"
else
  pass "socket-proxy blocked --privileged container"
fi

# ── 10. ASSERT: Squid blocks non-allowlisted domain ──────────────────────────
echo
echo "━━ Test: Squid blocks non-allowlisted domain ━━"
if docker run --rm \
  --user nobody \
  --network sandbox-net \
  --env HTTP_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env HTTPS_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env NO_PROXY="localhost,127.0.0.1,${SOCKET_PROXY_NAME}" \
  --env DOCKER_HOST="tcp://${SOCKET_PROXY_NAME}:${SOCKET_PROXY_PORT}" \
  -v "${DOOD_PROXY_ROOT}:/workspace" \
  -w /workspace \
  claude-sandbox-dood-cli:latest \
  curl -sf --max-time 5 http://example.com >/dev/null 2>&1; then
  fail "Squid allowed example.com — egress filter is not working"
else
  pass "Squid blocked example.com (not in allowlist)"
fi

# ── 11. ASSERT: tests pass inside sandbox ────────────────────────────────────
echo
echo "━━ Test: run-tests.sh inside sandbox ━━"
if docker run --rm \
  --user nobody \
  --network sandbox-net \
  --env HTTP_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env HTTPS_PROXY="http://${PROXY_NAME}:${PROXY_PORT}" \
  --env NO_PROXY="localhost,127.0.0.1,${SOCKET_PROXY_NAME}" \
  --env DOCKER_HOST="tcp://${SOCKET_PROXY_NAME}:${SOCKET_PROXY_PORT}" \
  -v "${DOOD_PROXY_ROOT}:/workspace" \
  -w /workspace \
  claude-sandbox-dood-cli:latest \
  bash -c './scripts/run-tests.sh'; then
  pass "run-tests.sh exited 0"
else
  fail "run-tests.sh exited non-zero"
fi
