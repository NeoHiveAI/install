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
# Requires either NEOHIVE_PAT in env or a cached PAT from a prior
# install run at $XDG_CACHE_HOME/neohive/ghcr-pat (~/.cache/...).
#
# Examples:
#   ./test/dry-run.sh                           # current host, cpu
#   BACKEND=rocm ./test/dry-run.sh              # simulate a ROCm host
#   ARCH=arm64 ./test/dry-run.sh                # simulate Apple Silicon
#   BACKEND=cuda FORCED=1 ./test/dry-run.sh     # simulate NEOHIVE_BACKEND=cuda

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

# install.sh's resolve_pat lives inside the main flow (which we
# skipped), so handle PAT lookup here. Docker login is still required
# because manifest inspect talks to the registry with the daemon's
# credentials.
if [ -n "${NEOHIVE_PAT:-}" ]; then
  PAT="$NEOHIVE_PAT"
elif [ -s "$PAT_FILE" ]; then
  PAT="$(cat "$PAT_FILE")"
else
  printf 'No PAT available. Set NEOHIVE_PAT or run install.sh once to cache one.\n' >&2
  exit 1
fi
printf '%s' "$PAT" | docker login ghcr.io -u neohive-service --password-stdin >/dev/null 2>&1 \
  || { printf 'docker login failed - PAT may be revoked.\n' >&2; exit 1; }

# Scenario inputs.
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|aarch64) ARCH_SUFFIX="-arm64" ;;
  *)             ARCH_SUFFIX="" ;;
esac
BACKEND="${BACKEND:-cpu}"
FORCED="${FORCED:-0}"

case "$BACKEND" in
  cpu|vulkan|cuda|rocm) ;;
  *) printf "Invalid BACKEND '%s' (expected cpu|vulkan|cuda|rocm)\n" "$BACKEND" >&2; exit 1 ;;
esac

printf '\n%s=== Dry-run: BACKEND=%s ARCH=%s FORCED=%s ===%s\n\n' \
  "$C_BOLD" "$BACKEND" "$ARCH" "$FORCED" "$C_RESET"

# Mirror step 6's dispatch. Kept inline rather than factored into a
# shared function because it is only three branches and the test
# harness wants each branch visible for debugging.
RESOLVED_TAG=""
if [ "$FORCED" -eq 1 ]; then
  TAG="${BACKEND}${ARCH_SUFFIX}"
  if try_pull_tag "$TAG"; then
    RESOLVED_TAG="$TAG"
  fi
else
  resolve_with_suffix "$ARCH_SUFFIX" || true
  if [ -z "$RESOLVED_TAG" ] && [ -n "$ARCH_SUFFIX" ]; then
    warn "no native $ARCH_SUFFIX image - would fall back to x86 under emulation"
    ARCH_SUFFIX=""
    resolve_with_suffix "" || true
  fi
fi

printf '\n'
if [ -n "$RESOLVED_TAG" ]; then
  printf '%sRESULT%s  would pull %s%s:%s%s (backend=%s)\n' \
    "$C_GREEN" "$C_RESET" "$C_CYAN" "$IMAGE" "$RESOLVED_TAG" "$C_RESET" "$BACKEND"
else
  printf '%sRESULT%s  no compatible image found\n' "$C_RED" "$C_RESET"
  exit 1
fi
