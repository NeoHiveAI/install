#!/usr/bin/env bash
# Smoke-test the installer. Expects NEOHIVE_LICENSE_FILE to point at a
# file containing a valid Keygen license key. Runs against the cpu
# variant (no GPU required) on port 13577 (non-default to avoid
# clobbering a local install).
#
# NeoHive images live on public Docker Hub, so no registry credentials
# are required to exercise the installer end-to-end.

set -euo pipefail

if [ -z "${NEOHIVE_LICENSE_FILE:-}" ]; then
  echo "NEOHIVE_LICENSE_FILE must be set (path to a file containing a license key)." >&2
  exit 1
fi
if [ ! -r "$NEOHIVE_LICENSE_FILE" ]; then
  echo "NEOHIVE_LICENSE_FILE=$NEOHIVE_LICENSE_FILE is not a readable file." >&2
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
curl -sf --max-time 10 http://localhost:13577/health >/dev/null
echo "   OK /health"

echo "-- Verifying frontend HTML --"
curl -sf --max-time 10 http://localhost:13577/ | grep -q '<html' || {
  echo "   FAIL frontend did not serve" >&2
  exit 1
}
echo "   OK frontend"

echo ""
echo "smoke passed"
