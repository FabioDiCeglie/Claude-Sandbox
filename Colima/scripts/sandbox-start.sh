#!/usr/bin/env bash
# Start the Colima VM sandbox.
#
# Isolation model — VM-level (hypervisor boundary, not just Linux namespaces):
#
#   Your Mac (host)
#     │
#     └── Colima VM "claude-sandbox"
#           ├── Only /workspace mounted from host project directory
#           ├── No ~/.aws, ~/.ssh, ~/.config, home dir, or host secrets
#           ├── Own Docker daemon (no access to host daemon)
#           └── Claude CLI runs here natively
#                 └── claude-sandbox-colima-app (tests · server, via VM Docker)
#
# Requirements:
#   brew install colima docker-buildx
#   (colima brings its own Docker daemon — Docker Desktop not required)
#
# On first start the VM is created from scratch; subsequent starts reuse the
# existing VM disk (tools stay installed).
set -euo pipefail

PROFILE="claude-sandbox"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CPU="${SANDBOX_CPU:-2}"
MEMORY="${SANDBOX_MEMORY:-4}"
DISK="${SANDBOX_DISK:-20}"

echo
echo "🚀  Start Colima VM sandbox"
echo

# ── 1. Verify colima is installed ─────────────────────────────────────────────
if ! command -v colima &>/dev/null; then
  echo "  ❌  colima not found. Install with: brew install colima" >&2
  exit 1
fi
echo "▶ colima $(colima version 2>/dev/null | head -1 || echo '(version unknown)')"

# ── 2. Start (or create) the VM ───────────────────────────────────────────────
echo
echo "▶ Starting Colima VM \"${PROFILE}\""
echo "  CPU: ${CPU}   Memory: ${MEMORY}GB   Disk: ${DISK}GB"
echo "  Mount: ${ROOT} → /workspace (only — no home dir)"
echo

if colima status "${PROFILE}" 2>/dev/null | grep -q "Running"; then
  echo "  ✅  VM already running"
else
  colima start "${PROFILE}" \
    --cpu "${CPU}" \
    --memory "${MEMORY}" \
    --disk "${DISK}" \
    --mount "${ROOT}:/workspace:w" \
    --runtime docker
  echo "  ✅  VM started"
fi

# ── 3. Wait for SSH to be ready ───────────────────────────────────────────────
# NOTE: colima ssh requires -p <profile> — it does NOT accept a positional arg.
echo
echo "▶ Waiting for VM SSH to be ready (up to 90s)"
ssh_ready=false
for _i in $(seq 1 45); do
  if colima ssh -p "${PROFILE}" -- /bin/echo ok >/dev/null 2>&1; then
    ssh_ready=true
    break
  fi
  sleep 2
done
if [[ "${ssh_ready}" != "true" ]]; then
  echo "  ERROR: VM SSH not ready after 90s" >&2
  colima ls 2>/dev/null || true
  exit 1
fi
echo "  ✅  SSH ready"

# ── 4. One-time tool provisioning (skipped on subsequent starts) ───────────────
echo
echo "▶ Checking tools inside VM"

colima ssh -p "${PROFILE}" -- bash --noprofile --norc -s 2>/dev/null << 'PROVISION'
set -euo pipefail

need_node=0
need_claude=0
need_uv=0

command -v node   >/dev/null 2>&1 || need_node=1
command -v claude >/dev/null 2>&1 || need_claude=1
command -v uv     >/dev/null 2>&1 || need_uv=1

if [[ "${need_node}" -eq 1 ]]; then
  echo "  Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y --no-install-recommends nodejs >/dev/null 2>&1
  echo "  Node.js $(node --version) installed"
else
  echo "  Node.js $(node --version) already present"
fi

if [[ "${need_claude}" -eq 1 ]]; then
  echo "  Installing Claude CLI..."
  sudo npm install -g @anthropic-ai/claude-code >/dev/null 2>&1
  echo "  claude CLI installed"
else
  echo "  claude CLI already present"
fi

if [[ "${need_uv}" -eq 1 ]]; then
  echo "  Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
  echo "  uv installed"
else
  echo "  uv already present"
fi
PROVISION

# ── 5. Lock .env files in workspace ───────────────────────────────────────────
echo
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

# ── 6. Summary ────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Colima VM sandbox ready"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  Isolation:  VM hypervisor (not just container namespaces)"
echo "  Mounts:     /workspace only — no host home dir, no ~/.aws, ~/.ssh"
echo "  Docker:     VM-internal daemon — host daemon NOT accessible"
echo "  Network:    internet-accessible (no egress filter in base variant)"
echo
echo "  Run \`claude\` when inside the VM."
echo "  Stop with: ./scripts/sandbox-stop.sh"
echo

# ── 7. Enter VM ───────────────────────────────────────────────────────────────
echo "▶ Entering Colima VM — you are now inside the sandbox"
echo

exec colima ssh -p "${PROFILE}" -- bash --noprofile --norc -c \
  'export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH" && cd /workspace && exec bash'
