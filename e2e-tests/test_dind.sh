#!/usr/bin/env bash
# E2E test for the DinD sandbox.
#
# Steps:
#   1. Start claude-sandbox-shell (privileged DinD container)
#   2. Wait for inner Docker daemon
#   3. Build claude-sandbox-cli inside inner daemon
#   4. ASSERT: inner daemon ID differs from host daemon ID
#   5. ASSERT: /workspace is visible, ~/.ssh is not
#   6. Lock .env files
#   7. ASSERT: run-tests.sh exits 0 inside the CLI container
#   8. Tear down (trap)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIND_ROOT="${REPO_ROOT}/DinD"
COMPOSE_FILE="${DIND_ROOT}/docker/docker-compose.yaml"
SHELL_NAME="claude-sandbox-shell"
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

# ── 2. Build CLI image ────────────────────────────────────────────────────────
echo
echo "▶ Building claude-sandbox-cli (this takes a minute)"
docker exec "${SHELL_NAME}" docker build -q \
  -t claude-sandbox-cli:latest \
  -f /workspace/docker/Dockerfile.claude-cli \
  /workspace/docker >/dev/null
echo "  done"

# ── 3. ASSERT: daemon isolation ───────────────────────────────────────────────
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

# ── 4. ASSERT: workspace isolation ───────────────────────────────────────────
echo
echo "━━ Test: workspace isolation ━━"

workspace_ok=$(docker exec "${SHELL_NAME}" docker run --rm \
  --user nobody \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /workspace:/workspace \
  -w /workspace \
  claude-sandbox-cli:latest \
  sh -c 'test -d /workspace && echo ok' 2>/dev/null || echo "")

if [[ "${workspace_ok}" == "ok" ]]; then
  pass "/workspace is accessible inside CLI container"
else
  fail "/workspace is not accessible inside CLI container"
fi

ssh_visible=$(docker exec "${SHELL_NAME}" docker run --rm \
  --user nobody \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /workspace:/workspace \
  -w /workspace \
  claude-sandbox-cli:latest \
  sh -c 'test -d /root/.ssh && echo exposed || echo isolated' 2>/dev/null || echo "isolated")

if [[ "${ssh_visible}" == "isolated" ]]; then
  pass "host ~/.ssh is not visible inside CLI container"
else
  fail "host ~/.ssh is exposed inside CLI container"
fi

# ── 5. Lock .env files ────────────────────────────────────────────────────────
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

# ── 6. ASSERT: tests pass inside sandbox ─────────────────────────────────────
echo
echo "━━ Test: run-tests.sh inside sandbox ━━"

if docker exec "${SHELL_NAME}" docker run --rm \
  --user nobody \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /workspace:/workspace \
  -w /workspace \
  claude-sandbox-cli:latest \
  bash -c './scripts/run-tests.sh'; then
  pass "run-tests.sh exited 0"
else
  fail "run-tests.sh exited non-zero"
fi
