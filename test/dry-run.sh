#!/usr/bin/env bash
# Dry-run the installer's tag resolver without pulling any images.
# Sources install.sh's helpers as a library, swaps try_pull_tag for a
# `docker manifest inspect` probe (no bytes transferred), and reports
# which tag the resolver would settle on for a given scenario.
#
# Scenarios (env vars, all optional):
#   BACKEND=cpu|vulkan|cuda|rocm   (default: cpu)
#   ARCH=arm64|x86_64|aarch64|...  (default: uname -m)
#   FORCED=0|1                     (default: 0; set 1 to simulate NEOHIVE_BACKEND)
#
# Examples:
#   ./test/dry-run.sh                           # current host, cpu
#   BACKEND=rocm ./test/dry-run.sh              # simulate a ROCm host
#   ARCH=arm64 ./test/dry-run.sh                # simulate Apple Silicon
#   BACKEND=cuda FORCED=1 ./test/dry-run.sh     # simulate NEOHIVE_BACKEND=cuda
#
# No registry credentials required — NeoHive images live on public
# Docker Hub, and `docker manifest inspect` talks to the registry
# without authentication for public repositories.

set -euo pipefail

cd "$(dirname "$0")/.."

NEOHIVE_LIB_ONLY=1
# shellcheck disable=SC1091
source ./install.sh

# Swap the real puller for a manifest probe. `docker manifest inspect`
# issues a HEAD-equivalent call against the registry and returns 0
# when the tag exists, non-zero otherwise. No image layers move.
try_pull_tag() {
  local tag="$1"
  info "probing $IMAGE:$tag"
  if docker manifest inspect "$IMAGE:$tag" >/dev/null 2>&1; then
    ok "exists"
    return 0
  fi
  return 1
}

# Scenario inputs.
ARCH="${ARCH:-$(uname -m)}"
BACKEND="${BACKEND:-cpu}"
FORCED="${FORCED:-0}"

case "$BACKEND" in
  cpu|vulkan|cuda|rocm) ;;
  *) printf "Invalid BACKEND '%s' (expected cpu|vulkan|cuda|rocm)\n" "$BACKEND" >&2; exit 1 ;;
esac

printf '\n%s=== Dry-run: BACKEND=%s ARCH=%s FORCED=%s ===%s\n\n' \
  "$C_BOLD" "$BACKEND" "$ARCH" "$FORCED" "$C_RESET"

# Mirror step 6's dispatch. Multi-arch manifest lists mean we do not
# suffix tags per architecture - docker pull selects the right layer
# from the manifest automatically.
RESOLVED_TAG=""
if [ "$FORCED" -eq 1 ]; then
  if try_pull_tag "$BACKEND"; then
    RESOLVED_TAG="$BACKEND"
  fi
else
  resolve_with_suffix "" || true
fi

printf '\n'
if [ -n "$RESOLVED_TAG" ]; then
  printf '%sRESULT%s  would pull %s%s:%s%s (backend=%s)\n' \
    "$C_GREEN" "$C_RESET" "$C_CYAN" "$IMAGE" "$RESOLVED_TAG" "$C_RESET" "$BACKEND"
else
  printf '%sRESULT%s  no compatible image found\n' "$C_RED" "$C_RESET"
  exit 1
fi
