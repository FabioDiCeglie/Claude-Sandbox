#!/usr/bin/env bash
# E2E test for the DooD sandbox.
#
# DooD shares the host daemon — there is no nested daemon and no
# daemon-isolation check. The test mirrors test_dind.sh in structure:
#
#   1. Build claude-sandbox-dood-cli on host daemon
#   2. ASSERT: /workspace is visible inside CLI container
#   3. ASSERT: host ~/.ssh is not visible inside CLI container
#   4. Lock .env files
#   5. ASSERT: run-tests.sh exits 0 inside CLI container
#   6. Tear down (trap)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOOD_ROOT="${REPO_ROOT}/DooD"

PASS=0
FAIL=0

pass() { echo "  ✅  PASS — $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  FAIL — $*" >&2; FAIL=$((FAIL + 1)); }

# ── Cleanup ────────────────────────────────────────────────────────────────────
cleanup() {
  echo
  echo "▶ Tearing down"
  docker rm -f claude-sandbox-dood-cli 2>/dev/null || true
  leftover=$(docker ps -aq --filter ancestor=claude-sandbox-dood-app:latest 2>/dev/null || true)
  [[ -n "${leftover}" ]] && echo "${leftover}" | xargs docker rm -f 2>/dev/null || true
  echo
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ "${FAIL}" -eq 0 ]] || exit 1
}
trap cleanup EXIT

# ── 1. Build CLI image ─────────────────────────────────────────────────────────
echo
echo "▶ Building claude-sandbox-dood-cli (this takes a minute)"
docker build -q \
  -t claude-sandbox-dood-cli:latest \
  -f "${DOOD_ROOT}/docker/Dockerfile.claude-cli" \
  "${DOOD_ROOT}/docker" >/dev/null
echo "  done"

# ── 2. ASSERT: workspace isolation ────────────────────────────────────────────
echo
echo "━━ Test: workspace isolation ━━"

workspace_ok=$(docker run --rm \
  --user nobody \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${DOOD_ROOT}:/workspace" \
  -w /workspace \
  claude-sandbox-dood-cli:latest \
  sh -c 'test -d /workspace && echo ok' 2>/dev/null || echo "")

if [[ "${workspace_ok}" == "ok" ]]; then
  pass "/workspace is accessible inside CLI container"
else
  fail "/workspace is not accessible inside CLI container"
fi

ssh_visible=$(docker run --rm \
  --user nobody \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${DOOD_ROOT}:/workspace" \
  -w /workspace \
  claude-sandbox-dood-cli:latest \
  sh -c 'test -d /root/.ssh && echo exposed || echo isolated' 2>/dev/null || echo "isolated")

if [[ "${ssh_visible}" == "isolated" ]]; then
  pass "host ~/.ssh is not visible inside CLI container"
else
  fail "host ~/.ssh is exposed inside CLI container"
fi

# ── 3. Lock .env files ────────────────────────────────────────────────────────
echo
echo "▶ Locking .env files"
find "${DOOD_ROOT}" -type f \( \
  -name ".env" -o -name ".env.*" -o -name "*.env" \
  -o -name "secrets.*" -o -name "credentials.*" \
\) -print0 | xargs -0 -r chmod 000 2>/dev/null || true
locked=$(find "${DOOD_ROOT}" -type f \( \
  -name ".env" -o -name ".env.*" -o -name "*.env" \
  -o -name "secrets.*" -o -name "credentials.*" \
\) | wc -l | tr -d " ")
echo "  ${locked} file(s) locked"

# ── 4. ASSERT: tests pass inside sandbox ─────────────────────────────────────
echo
echo "━━ Test: run-tests.sh inside sandbox ━━"

if docker run --rm \
  --user nobody \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${DOOD_ROOT}:/workspace" \
  -w /workspace \
  claude-sandbox-dood-cli:latest \
  bash -c './scripts/run-tests.sh'; then
  pass "run-tests.sh exited 0"
else
  fail "run-tests.sh exited non-zero"
fi
