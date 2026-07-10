#!/usr/bin/env bash
# E2E test for the Colima VM sandbox.
#
# In production, Claude runs natively inside a Colima VM and the VM's own
# Docker daemon is used for app containers. This test exercises the Docker
# layer that runs inside the VM — it does NOT start a Colima VM (that
# requires macOS + Colima and is not feasible on ubuntu-latest CI).
#
# What IS tested here (runnable on any Docker host):
#   1. Build claude-sandbox-colima-app image
#   2. ASSERT: /workspace is accessible inside the app container
#   3. Lock .env files
#   4. ASSERT: run-tests.sh exits 0 (build app image + pytest)
#   5. Tear down (trap)
#
# VM-level isolation (hypervisor boundary, colima start, SSH) must be
# verified manually on a macOS host with Colima installed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLIMA_ROOT="${REPO_ROOT}/Colima"

PASS=0
FAIL=0

pass() { echo "  ✅  PASS — $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  FAIL — $*" >&2; FAIL=$((FAIL + 1)); }

# ── Cleanup ────────────────────────────────────────────────────────────────────
cleanup() {
  echo
  echo "▶ Tearing down"
  leftover=$(docker ps -aq --filter ancestor=claude-sandbox-colima-app:latest 2>/dev/null || true)
  [[ -n "${leftover}" ]] && echo "${leftover}" | xargs docker rm -f 2>/dev/null || true
  echo
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ "${FAIL}" -eq 0 ]] || exit 1
}
trap cleanup EXIT

# ── 1. Build app image ────────────────────────────────────────────────────────
echo
echo "▶ Building claude-sandbox-colima-app"
docker build -q \
  -t claude-sandbox-colima-app:latest \
  -f "${COLIMA_ROOT}/docker/Dockerfile" \
  "${COLIMA_ROOT}" >/dev/null
echo "  done"

# ── 2. ASSERT: /workspace is accessible ──────────────────────────────────────
echo
echo "━━ Test: workspace is accessible inside app container ━━"
workspace_ok=$(docker run --rm \
  -v "${COLIMA_ROOT}:/workspace" \
  -w /workspace \
  claude-sandbox-colima-app:latest \
  sh -c 'test -d /workspace && echo ok' 2>/dev/null || echo "")
if [[ "${workspace_ok}" == "ok" ]]; then
  pass "/workspace is accessible inside app container"
else
  fail "/workspace is not accessible inside app container"
fi

# ── 3. Lock .env files ────────────────────────────────────────────────────────
echo
echo "▶ Locking .env files"
find "${COLIMA_ROOT}" -type f \( \
  -name ".env" -o -name ".env.*" -o -name "*.env" \
  -o -name "secrets.*" -o -name "credentials.*" \
\) -print0 | xargs -0 -r chmod 000 2>/dev/null || true
locked=$(find "${COLIMA_ROOT}" -type f \( \
  -name ".env" -o -name ".env.*" -o -name "*.env" \
  -o -name "secrets.*" -o -name "credentials.*" \
\) | wc -l | tr -d " ")
echo "  ${locked} file(s) locked"

# ── 4. ASSERT: tests pass inside app container ───────────────────────────────
echo
echo "━━ Test: pytest passes inside app container ━━"
if docker run --rm \
  claude-sandbox-colima-app:latest \
  uv run pytest; then
  pass "pytest exited 0"
else
  fail "pytest exited non-zero"
fi
