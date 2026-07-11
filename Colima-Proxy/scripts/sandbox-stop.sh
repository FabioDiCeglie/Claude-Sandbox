#!/usr/bin/env bash
# Delete the Colima VM + Proxy sandbox entirely.
# Next sandbox-start.sh will recreate it from scratch (including Squid + iptables).
set -euo pipefail

PROFILE="claude-sandbox-proxy"

echo
echo "🛑  Stop Colima VM + Proxy sandbox"
echo

echo "▶ Deleting VM \"${PROFILE}\""
colima delete "${PROFILE}" --force 2>/dev/null \
  && echo "  ✅  VM \"${PROFILE}\" deleted" \
  || echo "  —  VM not found (already gone)"

echo
echo "  Colima + Proxy sandbox stopped."
