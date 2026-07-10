#!/usr/bin/env bash
# Delete the Colima VM sandbox entirely.
# Next sandbox-start.sh will recreate it from scratch.
set -euo pipefail

PROFILE="claude-sandbox"

echo
echo "🛑  Stop Colima VM sandbox"
echo

echo "▶ Deleting VM \"${PROFILE}\""
colima delete "${PROFILE}" --force 2>/dev/null \
  && echo "  ✅  VM \"${PROFILE}\" deleted" \
  || echo "  —  VM not found (already gone)"

echo
echo "  Colima sandbox stopped."
