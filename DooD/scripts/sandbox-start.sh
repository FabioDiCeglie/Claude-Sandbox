#!/usr/bin/env bash
# Start the DooD (Docker-outside-of-Docker) sandbox.
#
# Unlike DinD there is no privileged shell container and no nested daemon.
# The CLI container runs on the HOST daemon with the host socket bind-mounted.
#
#   Host Docker daemon (/var/run/docker.sock)
#       │
#       └── claude-sandbox-dood-cli   (Claude edits here)
#               └── claude-sandbox-dood-app  (tests · server)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_NAME="${SANDBOX_CLI_NAME:-claude-sandbox-dood-cli}"

echo
echo "🚀  Start DooD sandbox"
echo

echo "▶ Opening Docker socket for nobody"
# nobody (uid 65534) can't access the socket by default.
# Run a temporary root container to chmod it — mirrors DinD's approach.
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  alpine chmod 666 /var/run/docker.sock
echo "  ✅  socket accessible"

echo
echo "▶ Building claude-sandbox-dood-cli"
docker build -q \
  -t claude-sandbox-dood-cli:latest \
  -f "${ROOT}/docker/Dockerfile.claude-cli" \
  "${ROOT}/docker" >/dev/null 2>&1
echo "  ✅  claude-sandbox-dood-cli:latest"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Daemon note"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
host_id="$(docker info -f '{{.ID}}')"
echo "  Host daemon ID  ${host_id}"
echo
echo "  DooD shares the host Docker daemon — this is expected."
echo "  The CLI mounts the host socket directly (no nested daemon)."
echo "  Only /workspace is visible. Run \`claude\` when you're ready."
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
echo

echo "▶ Entering claude-sandbox-dood-cli"
echo

docker rm -f "${CLI_NAME}" >/dev/null 2>&1 || true

# Run as 'nobody' (uid 65534) so chmod 000 locks are effective.
# The host socket is mounted so docker commands inside the CLI hit the
# host daemon directly — same docker, different scope than DinD.
exec docker run --rm -it \
  --name "${CLI_NAME}" \
  --user nobody \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${ROOT}:/workspace" \
  -w /workspace \
  claude-sandbox-dood-cli:latest \
  bash
