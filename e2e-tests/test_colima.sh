#!/usr/bin/env bash
# E2E test for the Colima VM sandbox.
#
# Starts a real Colima VM with only the workspace mounted and verifies
# VM-level isolation and functionality.
#
# Requirements: macOS + colima (brew install colima docker-buildx)
#
# Steps:
#   1. Start Colima VM "claude-sandbox-e2e" with workspace-only mount
#   2. ASSERT: SSH into VM works
#   3. ASSERT: /workspace is accessible inside VM
#   4. ASSERT: host /Users is NOT accessible inside VM (no home-dir mount)
#   5. ASSERT: VM has its own Docker daemon (host daemon unreachable)
#   6. Provision tools inside VM (Node, uv)
#   7. ASSERT: run-tests.sh exits 0 inside VM
#   8. Tear down (trap)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLIMA_ROOT="${REPO_ROOT}/Colima"
PROFILE="claude-sandbox-e2e"

PASS=0
FAIL=0

pass() { echo "  ✅  PASS — $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  FAIL — $*" >&2; FAIL=$((FAIL + 1)); }

# ── Cleanup ────────────────────────────────────────────────────────────────────
cleanup() {
  echo
  echo "▶ Tearing down"
  colima delete "${PROFILE}" --force 2>/dev/null || true
  echo
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ "${FAIL}" -eq 0 ]] || exit 1
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
echo
echo "▶ Checking prerequisites"
if ! command -v colima &>/dev/null; then
  echo "  ❌  colima not found — install with: brew install colima" >&2
  exit 1
fi
echo "  colima $(colima version 2>/dev/null | head -1)"

# ── 1. Start VM ───────────────────────────────────────────────────────────────
echo
echo "▶ Starting Colima VM \"${PROFILE}\" (workspace-only mount)"
colima start "${PROFILE}" \
  --cpu 2 \
  --memory 4 \
  --disk 20 \
  --mount "${COLIMA_ROOT}:/workspace:w" \
  --runtime docker
echo "  done"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
echo
echo "▶ Waiting for VM SSH (up to 90s)"
for _i in $(seq 1 45); do
  if colima ssh -p "${PROFILE}" -- /bin/echo ok >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# ── 2. ASSERT: SSH works ──────────────────────────────────────────────────────
echo
echo "━━ Test: SSH into VM ━━"
if colima ssh -p "${PROFILE}" -- /bin/echo ok >/dev/null 2>&1; then
  pass "SSH into VM works"
else
  fail "SSH into VM failed"
fi

# ── 3. ASSERT: /workspace accessible ─────────────────────────────────────────
echo
echo "━━ Test: /workspace is accessible inside VM ━━"
workspace_ok=$(colima ssh -p "${PROFILE}" -- \
  bash --noprofile --norc -c 'test -d /workspace && echo ok' 2>/dev/null || echo "")
if [[ "${workspace_ok}" == "ok" ]]; then
  pass "/workspace is accessible inside VM"
else
  fail "/workspace is NOT accessible inside VM"
fi

# ── 4. ASSERT: host /Users NOT accessible ────────────────────────────────────
echo
echo "━━ Test: host /Users is not mounted in VM ━━"
users_visible=$(colima ssh -p "${PROFILE}" -- \
  bash --noprofile --norc -c 'ls /Users 2>/dev/null | wc -l | tr -d " "' 2>/dev/null || echo "0")
if [[ "${users_visible}" == "0" ]]; then
  pass "Host /Users is not accessible inside VM"
else
  fail "Host /Users IS accessible inside VM — isolation broken"
fi

# ── 5. ASSERT: VM has its own Docker daemon ───────────────────────────────────
echo
echo "━━ Test: VM has its own Docker daemon ━━"
docker_ok=$(colima ssh -p "${PROFILE}" -- \
  bash --noprofile --norc -c 'docker info >/dev/null 2>&1 && echo ok || echo fail' 2>/dev/null || echo "fail")
if [[ "${docker_ok}" == "ok" ]]; then
  pass "VM Docker daemon is running"
else
  fail "VM Docker daemon is not available"
fi

# ── 6. Provision tools in VM ──────────────────────────────────────────────────
echo
echo "▶ Provisioning tools inside VM"
colima ssh -p "${PROFILE}" -- bash --noprofile --norc -s 2>/dev/null << 'PROVISION'
set -euo pipefail
command -v node >/dev/null 2>&1 || {
  echo "  Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y --no-install-recommends nodejs >/dev/null 2>&1
  echo "  Node.js $(node --version) installed"
}
command -v uv >/dev/null 2>&1 || {
  echo "  Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
  echo "  uv installed"
}
PROVISION

# ── 7. ASSERT: run-tests.sh passes inside VM ─────────────────────────────────
echo
echo "━━ Test: run-tests.sh inside VM ━━"
if colima ssh -p "${PROFILE}" -- bash --noprofile --norc -c \
    'export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH" && cd /workspace && ./scripts/run-tests.sh' 2>&1; then
  pass "run-tests.sh exited 0 inside VM"
else
  fail "run-tests.sh exited non-zero inside VM"
fi
