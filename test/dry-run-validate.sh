#!/usr/bin/env bash
# Dry-run the installer's validation paths without pulling images or
# starting a container. Sources install.sh as a library and exercises:
#
#   1. resolve_container_fingerprint  - generates/loads the UUID that
#      the preflight and runtime will both use.
#   2. preflight_validate_license     - posts to api.keygen.sh and
#      reports VALID / NO_MACHINES / rejection / network.
#   3. docker manifest inspect        - confirms the public Docker Hub
#      image is reachable without authentication.
#
# Inputs (env):
#   NEOHIVE_LICENSE_FILE  - path to a file containing the license key.
#                           Required unless a key is already cached at
#                           ~/.cache/neohive/license-key.
#   NEOHIVE_ROTATE_LICENSE - honoured exactly like the real installer.
#
# Exit codes: 0 if both validations pass, non-zero otherwise.

set -euo pipefail

cd "$(dirname "$0")/.."

NEOHIVE_LIB_ONLY=1
# shellcheck disable=SC1091
source ./install.sh

separator() {
  local line
  line=$(printf '%*s' 67 '' | tr ' ' '-')
  printf '\n   %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
}

# -- Fingerprint -------------------------------------------------------
separator
printf '   %s[fingerprint]%s resolving UUID the gateway will see at boot\n' "$C_BOLD" "$C_RESET"
fp="$(resolve_container_fingerprint)"
if [ -n "$fp" ]; then
  info "resolved fingerprint: $fp"
  if [ -s "$FP_CACHE_FILE" ]; then
    info "host cache file:     $FP_CACHE_FILE ($(wc -c < "$FP_CACHE_FILE") bytes)"
  fi
  ok "fingerprint OK"
else
  fail E601 "resolve_container_fingerprint returned empty"
fi

# -- License preflight -------------------------------------------------
separator
printf '   %s[license]%s validating against api.keygen.sh\n' "$C_BOLD" "$C_RESET"
LICENSE_KEY="$(resolve_license)"
if [ -z "$LICENSE_KEY" ]; then
  printf '      %sFAIL%s  no license key available - set NEOHIVE_LICENSE_FILE or cache one at %s\n' \
    "$C_RED" "$C_RESET" "$LICENSE_CACHE_FILE" >&2
  exit 1
fi
info "license key (masked): ${LICENSE_KEY:0:4}***${LICENSE_KEY: -4} (len=${#LICENSE_KEY})"
if preflight_validate_license; then
  LICENSE_RESULT=0
else
  LICENSE_RESULT=1
fi

# -- Registry connectivity --------------------------------------------
separator
printf '   %s[registry]%s probing public Docker Hub image\n' "$C_BOLD" "$C_RESET"

# NeoHive images are published to public Docker Hub - no authentication
# is required to pull or inspect, so this stage just verifies that the
# registry is reachable and the floating :cpu tag exists.
REGISTRY_RESULT=0
if docker manifest inspect "$IMAGE:cpu" >/dev/null 2>&1; then
  ok "manifest read on $IMAGE:cpu OK"
else
  printf '      %sFAIL%s  manifest inspect on %s:cpu failed - Docker Hub unreachable or image missing\n' \
    "$C_RED" "$C_RESET" "$IMAGE" >&2
  REGISTRY_RESULT=1
fi

# -- Summary -----------------------------------------------------------
separator
if [ "$LICENSE_RESULT" -eq 0 ] && [ "$REGISTRY_RESULT" -eq 0 ]; then
  printf '   %sALL VALIDATIONS PASSED%s\n\n' "$C_GREEN$C_BOLD" "$C_RESET"
  exit 0
fi
[ "$LICENSE_RESULT" -ne 0 ] && printf '   %sFAIL%s license preflight\n' "$C_RED" "$C_RESET" >&2
[ "$REGISTRY_RESULT" -ne 0 ] && printf '   %sFAIL%s registry probe\n' "$C_RED" "$C_RESET" >&2
printf '\n'
exit 1
