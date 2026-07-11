#!/usr/bin/env bash
# Start the Colima VM + Proxy sandbox.
#
# Network topology (inside the Colima VM):
#
#   Your Mac (host)
#     │
#     └── Colima VM "claude-sandbox-proxy"
#           ├── Only /workspace mounted from host project directory
#           ├── No ~/.aws, ~/.ssh, ~/.config, home dir, or host secrets
#           ├── Own Docker daemon (no access to host daemon)
#           │     └── Configured to pull images via Squid
#           │
#           ├── Squid egress proxy (port 3128, domain allowlist)
#           │     └── Only allowlisted domains pass — everything else is denied
#           │
#           ├── iptables OUTPUT rules (kernel-level enforcement)
#           │     └── Direct port 80/443 blocked for all non-proxy users
#           │         Squid (user "proxy") is the only path to the internet
#           │
#           └── Claude CLI runs here (HTTP_PROXY / HTTPS_PROXY → Squid)
#
# Two layers of enforcement:
#   1. Proxy env vars  → tools that respect them are routed through Squid
#   2. iptables        → blocks direct port 80/443 even from proxy-unaware tools
#
# Requirements:
#   brew install colima docker-buildx
#
# On first start the VM is created from scratch; subsequent starts reuse the
# existing VM disk (tools stay installed, iptables rules are re-applied).
set -euo pipefail

PROFILE="claude-sandbox-proxy"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CPU="${SANDBOX_CPU:-2}"
MEMORY="${SANDBOX_MEMORY:-4}"
DISK="${SANDBOX_DISK:-20}"
SQUID_PORT="3128"

echo
echo "🚀  Start Colima VM + Proxy sandbox"
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

# ── 4. Provision tools + Squid + iptables inside VM ──────────────────────────
#
# Order matters:
#   a) Install system packages (apt-get needs free internet → before iptables)
#   b) Install Node.js / Claude CLI / uv (curl/npm → before iptables)
#   c) Configure and start Squid
#   d) Configure Docker daemon to use Squid (image pulls via proxy)
#   e) Apply iptables rules LAST — locks down direct 80/443 access
#
echo
echo "▶ Provisioning VM (tools + Squid + iptables)"

colima ssh -p "${PROFILE}" -- bash --noprofile --norc -s 2>/dev/null << PROVISION
set -euo pipefail

# ── a) System packages ────────────────────────────────────────────────────────
echo "  Checking system packages..."

need_pkgs=0
command -v squid    >/dev/null 2>&1 || need_pkgs=1
command -v iptables >/dev/null 2>&1 || need_pkgs=1
command -v nc       >/dev/null 2>&1 || need_pkgs=1

if [[ "\${need_pkgs}" -eq 1 ]]; then
  echo "  Installing squid, iptables, netcat..."
  sudo apt-get update -qq >/dev/null 2>&1
  sudo apt-get install -y --no-install-recommends \
    squid iptables netcat-openbsd conntrack >/dev/null 2>&1
  echo "  ✅  System packages installed"
else
  echo "  ✅  System packages already present"
fi

# ── b) Node.js / Claude CLI / uv ─────────────────────────────────────────────
echo "  Checking dev tools..."

command -v node   >/dev/null 2>&1 || {
  echo "  Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y --no-install-recommends nodejs >/dev/null 2>&1
  echo "  ✅  Node.js \$(node --version)"
} && echo "  ✅  Node.js \$(node --version) already present"

command -v claude >/dev/null 2>&1 || {
  echo "  Installing Claude CLI..."
  sudo npm install -g @anthropic-ai/claude-code >/dev/null 2>&1
  echo "  ✅  claude CLI installed"
} && echo "  ✅  claude CLI already present"

command -v uv >/dev/null 2>&1 || {
  echo "  Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
  echo "  ✅  uv installed"
} && echo "  ✅  uv already present"

# ── c) Configure and start Squid ─────────────────────────────────────────────
echo "  Configuring Squid..."

sudo cp /workspace/squid/squid.conf /etc/squid/squid.conf
sudo chown root:root /etc/squid/squid.conf

# Ensure log directories exist with correct permissions
sudo mkdir -p /var/log/squid /var/spool/squid
sudo chown -R proxy:proxy /var/log/squid /var/spool/squid 2>/dev/null || true

# Initialise Squid cache dirs (idempotent)
sudo squid -z -f /etc/squid/squid.conf 2>/dev/null || true

# Start or restart Squid
if systemctl is-active --quiet squid 2>/dev/null; then
  sudo systemctl restart squid
else
  sudo systemctl enable squid 2>/dev/null || true
  sudo systemctl start  squid 2>/dev/null || sudo service squid start 2>/dev/null || true
fi

# Wait for Squid to accept connections (up to 15s)
squid_ready=false
for _i in \$(seq 1 15); do
  nc -z 127.0.0.1 ${SQUID_PORT} >/dev/null 2>&1 && { squid_ready=true; break; }
  sleep 1
done
if [[ "\${squid_ready}" != "true" ]]; then
  echo "  ❌  Squid did not start within 15s" >&2
  sudo journalctl -u squid -n 20 2>/dev/null || sudo tail -20 /var/log/squid/cache.log 2>/dev/null || true
  exit 1
fi
echo "  ✅  Squid running on :${SQUID_PORT}"

# ── d) Configure Docker daemon proxy ─────────────────────────────────────────
# Docker image pulls (docker build, docker pull) are routed through Squid so
# they are also subject to the domain allowlist.
echo "  Configuring Docker daemon proxy..."

sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null << 'DOCKERPROXY'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:3128"
Environment="HTTPS_PROXY=http://127.0.0.1:3128"
Environment="NO_PROXY=localhost,127.0.0.1"
DOCKERPROXY

sudo systemctl daemon-reload 2>/dev/null || true
sudo systemctl restart docker 2>/dev/null || true

# Wait for Docker to come back up (up to 20s)
for _i in \$(seq 1 20); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done
docker info >/dev/null 2>&1 && echo "  ✅  Docker daemon proxy configured" \
  || { echo "  ❌  Docker daemon did not restart" >&2; exit 1; }

# ── e) Apply iptables rules — kernel-level egress enforcement ─────────────────
#
# Two-layer enforcement:
#   Layer 1 (env vars):  HTTP_PROXY / HTTPS_PROXY route compliant tools via Squid
#   Layer 2 (iptables):  Block direct port 80/443 so bypass attempts also fail
#
# Rules are flushed and re-applied every start to ensure idempotency.
#
# Who can reach the internet on ports 80/443:
#   user "proxy"  — Squid (the only allowed outbound path)
#   loopback      — always allowed
#   ESTABLISHED   — responses to already-accepted connections
#   DNS (53)      — needed by all processes including Squid itself
#   SSH (22)      — Colima management SSH must remain open
#
# Everyone else (including the SSH user running Claude CLI) cannot open
# direct port 80/443 connections — they must go through Squid.
echo "  Applying iptables egress rules..."

# Flush the OUTPUT chain (idempotent re-apply)
sudo iptables -F OUTPUT

# Loopback — always unrestricted
sudo iptables -A OUTPUT -o lo -j ACCEPT

# Squid (runs as OS user "proxy" in Ubuntu/Debian) — allowed direct internet
sudo iptables -A OUTPUT -m owner --uid-owner proxy -j ACCEPT

# DNS — all processes need name resolution
sudo iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Established / related — allow response traffic for accepted connections
sudo iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# SSH — keep Colima management channel open
sudo iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT

# Block direct HTTP/HTTPS — everything else must go through Squid
sudo iptables -A OUTPUT -p tcp --dport 80  -j REJECT --reject-with tcp-reset
sudo iptables -A OUTPUT -p tcp --dport 443 -j REJECT --reject-with tcp-reset

echo "  ✅  iptables egress rules applied"
echo "      Direct port 80/443 blocked — Squid is the only exit"

PROVISION

echo "  ✅  VM provisioning complete"

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
echo "  Colima VM + Proxy sandbox ready"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  Isolation:   VM hypervisor (not just container namespaces)"
echo "  Mounts:      /workspace only — no host home dir, no ~/.aws, ~/.ssh"
echo "  Docker:      VM-internal daemon — host daemon NOT accessible"
echo "  Egress:      Squid allowlist on :${SQUID_PORT} + iptables kernel block"
echo "  Allowlist:   anthropic.com, pypi.org, npmjs.com, github.com, docker.io, ..."
echo
echo "  Run \`claude\` when inside the VM."
echo "  Stop with: ./scripts/sandbox-stop.sh"
echo

# ── 7. Enter VM with proxy env vars set ──────────────────────────────────────
echo "▶ Entering Colima VM — you are now inside the sandbox"
echo

exec colima ssh -p "${PROFILE}" -- bash --noprofile --norc -c "
  export PATH=\"\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH\"
  export HTTP_PROXY=\"http://127.0.0.1:${SQUID_PORT}\"
  export HTTPS_PROXY=\"http://127.0.0.1:${SQUID_PORT}\"
  export http_proxy=\"http://127.0.0.1:${SQUID_PORT}\"
  export https_proxy=\"http://127.0.0.1:${SQUID_PORT}\"
  export NO_PROXY=\"localhost,127.0.0.1\"
  export no_proxy=\"localhost,127.0.0.1\"
  cd /workspace
  exec bash
"
