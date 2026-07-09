#!/usr/bin/env bash
# Start claude-sandbox-shell, build claude-sandbox-cli inside it, open a bash shell.
# You run `claude` yourself once inside — see CLAUDE.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT}/docker/docker-compose.yaml"
SHELL_NAME="${SANDBOX_SHELL_NAME:-claude-sandbox-shell}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-90}"

cd "${ROOT}"

echo
echo "🚀  Start claude-sandbox-shell"
echo

echo "▶ Starting shell container"
docker compose -f "${COMPOSE_FILE}" --profile sandbox up -d shell
echo "  ✅  ${SHELL_NAME} running"

echo
echo "▶ Waiting for inner Docker daemon"
deadline=$((SECONDS + MAX_WAIT_SECONDS))
until docker exec "${SHELL_NAME}" docker info >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "  ❌  claude-sandbox-shell not ready after ${MAX_WAIT_SECONDS}s" >&2
    exit 1
  fi
  sleep 1
done
echo "  ✅  inner daemon ready"

# Allow the CLI container (running as nobody) to reach the inner Docker socket.
# Without this, nobody gets "permission denied" on the Unix socket file.
docker exec "${SHELL_NAME}" chmod 666 /var/run/docker.sock

echo
echo "▶ Building claude-sandbox-cli inside shell"
docker exec "${SHELL_NAME}" docker build -q \
  -t claude-sandbox-cli:latest \
  -f /workspace/docker/Dockerfile.claude-cli \
  /workspace/docker >/dev/null 2>&1
echo "  ✅  claude-sandbox-cli:latest"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Isolation check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  Your Mac has its own Docker daemon (host)."
echo "  claude-sandbox-shell runs a second daemon inside — sandboxed."
echo

host_id="$(docker info -f '{{.ID}}')"
inner_id="$(docker exec "${SHELL_NAME}" docker info -f '{{.ID}}')"

echo "  Host daemon ID     ${host_id}"
echo "  Shell daemon ID    ${inner_id}"
echo

if [[ "${host_id}" == "${inner_id}" ]]; then
  echo "  ⚠️  Same ID — something is wrong, daemons are not isolated."
  exit 1
fi

echo "  ✅  Different IDs — the shell has its own Docker, separate from your Mac."
echo
echo "  Next you'll enter claude-sandbox-cli. From there, every"
echo "  \`docker run\` goes through the shell's daemon — not host Docker."
echo "  Only /workspace is visible. Run \`claude\` when you're ready."
echo

echo "▶ Locking .env files in workspace"
# Find every .env-style file and make it unreadable.
# This runs as root inside the shell container so it reliably sets the bits
# before the CLI container (which runs as nobody) mounts the same path.
docker exec "${SHELL_NAME}" sh -c '
  find /workspace -type f \( \
    -name ".env" -o -name ".env.*" -o -name "*.env" \
    -o -name "secrets.*" -o -name "credentials.*" \
  \) -print0 \
  | xargs -0 -r chmod 000
'
locked=$(docker exec "${SHELL_NAME}" sh -c '
  find /workspace -type f \( \
    -name ".env" -o -name ".env.*" -o -name "*.env" \
    -o -name "secrets.*" -o -name "credentials.*" \
  \) | wc -l | tr -d " "
')
echo "  ✅  ${locked} secret file(s) locked (chmod 000)"
echo

echo "▶ Entering claude-sandbox-cli"
echo

# Run as 'nobody' (uid 65534) so chmod 000 locks are effective.
exec docker exec -it "${SHELL_NAME}" docker run --rm -it \
  --user nobody \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /workspace:/workspace \
  -w /workspace \
  claude-sandbox-cli:latest \
  bash
