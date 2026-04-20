#!/usr/bin/env bash
# Smoke-test the installer. Expects NEOHIVE_PAT to be set in the environment.
# Runs against the cpu variant (no GPU required) on port 13577 (non-default
# to avoid clobbering a local install).

set -euo pipefail

if [ -z "${NEOHIVE_PAT:-}" ]; then
  echo "NEOHIVE_PAT must be set for the smoke test." >&2
  exit 1
fi

TMPCACHE="$(mktemp -d)"
trap 'rm -rf "$TMPCACHE"; docker rm -f neohive 2>/dev/null || true' EXIT

echo "-- Running installer via process substitution --"
NEOHIVE_BACKEND=cpu \
NEOHIVE_PORT=13577 \
XDG_CACHE_HOME="$TMPCACHE" \
bash ./install.sh

echo "-- Verifying /health --"
curl -sf http://localhost:13577/health >/dev/null
echo "   OK /health"

echo "-- Verifying frontend HTML --"
curl -sf http://localhost:13577/ | grep -q '<html' || {
  echo "   FAIL frontend did not serve" >&2
  exit 1
}
echo "   OK frontend"

echo ""
echo "smoke passed"
