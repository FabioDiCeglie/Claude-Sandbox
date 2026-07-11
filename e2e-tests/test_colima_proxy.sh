#!/usr/bin/env bash
# E2E test for the Colima VM + Proxy sandbox.
#
# LOCAL-ONLY: Colima requires a real macOS host with working hypervisor access.
# Run manually: bash e2e-tests/test_colima_proxy.sh
#
# Requirements: macOS + colima (brew install colima docker docker-buildx qemu)
#
# Steps:
#   1.  Start Colima VM with workspace-only mount
#   2.  ASSERT: SSH into VM works
#   3.  ASSERT: /workspace is accessible inside VM
#   4.  ASSERT: host /Users is NOT accessible inside VM
#   5.  ASSERT: VM Docker daemon is running
#   6.  Provision tools + Squid + iptables inside VM
#   7.  ASSERT: Squid is running on :3128
#   8.  ASSERT: Squid blocks a non-allowlisted domain (example.com)
#   9.  ASSERT: Squid allows an allowlisted domain (pypi.org)
#  10.  ASSERT: iptables blocks direct port 443 (proxy bypass attempt)
#  11.  ASSERT: run-tests.sh exits 0 inside VM
#  12.  Tear down (trap)
set -euo pipefail

if [[ -n "${CI:-}" ]]; then
  echo "⚠  Colima e2e tests are local-only (CI detected — skipping)."
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLIMA_PROXY_ROOT="${REPO_ROOT}/Colima-Proxy"
PROFILE="claude-sandbox-proxy-e2e"
SQUID_PORT="3128"

PASS=0
FAIL=0

pass() { echo "  ✅  PASS — $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌  FAIL — $*" >&2; FAIL=$((FAIL + 1)); }

# ── Cleanup ───────────────────────────────────────────────────────────────────
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
  echo "  ❌  colima not found — install with: brew install colima docker docker-buildx qemu" >&2
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
  --mount "${COLIMA_PROXY_ROOT}:/workspace:w" \
  --runtime docker
echo "  done"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
echo
echo "▶ Waiting for VM SSH (up to 90s)"
for _i in $(seq 1 45); do
  colima ssh -p "${PROFILE}" -- /bin/echo ok >/dev/null 2>&1 && break
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
result=$(colima ssh -p "${PROFILE}" -- \
  bash --noprofile --norc -c 'test -d /workspace && echo ok' 2>/dev/null || echo "")
if [[ "${result}" == "ok" ]]; then
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

# ── 5. ASSERT: VM Docker daemon running ───────────────────────────────────────
echo
echo "━━ Test: VM Docker daemon ━━"
docker_ok=$(colima ssh -p "${PROFILE}" -- \
  bash --noprofile --norc -c 'docker info >/dev/null 2>&1 && echo ok || echo fail' 2>/dev/null || echo "fail")
if [[ "${docker_ok}" == "ok" ]]; then
  pass "VM Docker daemon is running"
else
  fail "VM Docker daemon is not available"
fi

# ── 6. Provision tools + Squid + iptables ─────────────────────────────────────
echo
echo "▶ Provisioning VM (tools + Squid + iptables)"
echo "  This takes ~3–6 min on first boot..."

colima ssh -p "${PROFILE}" -- bash --noprofile --norc -s 2>/dev/null << PROVISION
set -euo pipefail

# System packages
command -v squid    >/dev/null 2>&1 || {
  sudo apt-get update -qq >/dev/null 2>&1
  sudo apt-get install -y --no-install-recommends \
    squid iptables netcat-openbsd conntrack >/dev/null 2>&1
}

# Dev tools
command -v node >/dev/null 2>&1 || {
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y --no-install-recommends nodejs >/dev/null 2>&1
}
command -v uv >/dev/null 2>&1 || {
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
}

# Configure and start Squid
sudo cp /workspace/squid/squid.conf /etc/squid/squid.conf
sudo chown root:root /etc/squid/squid.conf
if ! sudo squid -k check -f /etc/squid/squid.conf 2>/dev/null; then
  sudo squid -k check -f /etc/squid/squid.conf || true
  exit 1
fi
sudo mkdir -p /var/log/squid /var/spool/squid
sudo chown -R proxy:proxy /var/log/squid /var/spool/squid 2>/dev/null || true
sudo squid -z -f /etc/squid/squid.conf 2>/dev/null || true
sudo systemctl stop squid 2>/dev/null || sudo service squid stop 2>/dev/null || true
sleep 1
sudo systemctl start squid 2>/dev/null || sudo service squid start 2>/dev/null || true
for _i in \$(seq 1 30); do nc -z 127.0.0.1 3128 >/dev/null 2>&1 && break; sleep 1; done

# Configure Docker daemon proxy
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null << 'DOCKERPROXY'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:3128"
Environment="HTTPS_PROXY=http://127.0.0.1:3128"
Environment="NO_PROXY=localhost,127.0.0.1"
DOCKERPROXY
sudo systemctl daemon-reload 2>/dev/null || true
sudo systemctl restart docker 2>/dev/null || true
for _i in \$(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 1; done

# Pre-pull the app base image while internet is still unrestricted.
# Docker daemon proxy (above) routes pulls through Squid once iptables locks
# down direct access, but pre-pulling guarantees the layer is cached even if
# the daemon proxy handoff has a timing edge on first boot.
docker pull python:3.11-slim >/dev/null 2>&1 || true

# Apply iptables rules (last — so installs above had free internet)
sudo iptables -F OUTPUT
sudo iptables -A OUTPUT -o lo -j ACCEPT
sudo iptables -A OUTPUT -m owner --uid-owner proxy -j ACCEPT
sudo iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
sudo iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 80  -j REJECT --reject-with tcp-reset
sudo iptables -A OUTPUT -p tcp --dport 443 -j REJECT --reject-with tcp-reset
PROVISION

echo "  done"

# ── 7. ASSERT: Squid is running on :3128 ──────────────────────────────────────
echo
echo "━━ Test: Squid is running on :${SQUID_PORT} ━━"
squid_up=$(colima ssh -p "${PROFILE}" -- \
  bash --noprofile --norc -c \
  "nc -z 127.0.0.1 ${SQUID_PORT} >/dev/null 2>&1 && echo ok || echo fail" 2>/dev/null || echo "fail")
if [[ "${squid_up}" == "ok" ]]; then
  pass "Squid is accepting connections on :${SQUID_PORT}"
else
  fail "Squid is not listening on :${SQUID_PORT}"
fi

# ── 8. ASSERT: Squid blocks non-allowlisted domain ────────────────────────────
echo
echo "━━ Test: Squid blocks non-allowlisted domain (example.com) ━━"
blocked=$(colima ssh -p "${PROFILE}" -- \
  bash --noprofile --norc -c \
  'HTTP_PROXY=http://127.0.0.1:3128 HTTPS_PROXY=http://127.0.0.1:3128 \
   curl -sf --max-time 5 https://example.com >/dev/null 2>&1 && echo allowed || echo blocked' \
  2>/dev/null || echo "blocked")
if [[ "${blocked}" == "blocked" ]]; then
  pass "Squid blocked example.com (not in allowlist)"
else
  fail "Squid allowed example.com — egress filter is not working"
fi

# ── 9. ASSERT: Squid allows allowlisted domain ────────────────────────────────
echo
echo "━━ Test: Squid allows allowlisted domain (pypi.org) ━━"
allowed=$(colima ssh -p "${PROFILE}" -- \
  bash --noprofile --norc -c \
  'HTTP_PROXY=http://127.0.0.1:3128 HTTPS_PROXY=http://127.0.0.1:3128 \
   curl -sf --max-time 15 https://pypi.org >/dev/null 2>&1 && echo allowed || echo blocked' \
  2>/dev/null || echo "blocked")
if [[ "${allowed}" == "allowed" ]]; then
  pass "Squid allowed pypi.org (in allowlist)"
else
  fail "Squid blocked pypi.org — allowlist or Squid misconfiguration"
fi

# ── 10. ASSERT: iptables blocks direct port 443 ───────────────────────────────
echo
echo "━━ Test: iptables blocks direct port 443 (proxy bypass attempt) ━━"
direct=$(colima ssh -p "${PROFILE}" -- \
  bash --noprofile --norc -c \
  'curl --noproxy "*" -sf --max-time 5 https://example.com >/dev/null 2>&1 && echo allowed || echo blocked' \
  2>/dev/null || echo "blocked")
if [[ "${direct}" == "blocked" ]]; then
  pass "iptables blocked direct port 443 connection — proxy cannot be bypassed"
else
  fail "Direct port 443 connection succeeded — iptables rules are not enforced"
fi

# ── 11. ASSERT: run-tests.sh passes inside VM ────────────────────────────────
echo
echo "━━ Test: run-tests.sh inside VM ━━"
if colima ssh -p "${PROFILE}" -- bash --noprofile --norc -c \
    'export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH" && cd /workspace && ./scripts/run-tests.sh' 2>&1; then
  pass "run-tests.sh exited 0 inside VM"
else
  fail "run-tests.sh exited non-zero inside VM"
fi
