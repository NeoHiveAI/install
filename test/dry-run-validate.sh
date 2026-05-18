#!/usr/bin/env bash
# Dry-run the installer's credential validation paths without pulling
# images or starting a container. Sources install.sh as a library and
# exercises:
#
#   1. resolve_container_fingerprint  - generates/loads the UUID that
#      the preflight and runtime will both use.
#   2. preflight_validate_license     - posts to api.keygen.sh and
#      reports VALID / NO_MACHINES / rejection / network.
#   3. docker login ghcr.io           - validates the cached PAT against
#      the real registry. Restores prior login state when done.
#
# Inputs (env):
#   NEOHIVE_LICENSE_KEY   - license to validate. Required unless a
#                           license is already cached at
#                           ~/.cache/neohive/license-key.
#   NEOHIVE_PAT           - PAT to validate. Falls back to
#                           ~/.cache/neohive/ghcr-pat when unset.
#   NEOHIVE_ROTATE_*      - honoured exactly like the real installer.
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
  printf '      %sFAIL%s  no license key available - set NEOHIVE_LICENSE_KEY or cache one at %s\n' \
    "$C_RED" "$C_RESET" "$LICENSE_FILE" >&2
  exit 1
fi
info "license key (masked): ${LICENSE_KEY:0:4}***${LICENSE_KEY: -4} (len=${#LICENSE_KEY})"
if preflight_validate_license; then
  LICENSE_RESULT=0
else
  LICENSE_RESULT=1
fi

# -- GHCR PAT ----------------------------------------------------------
separator
printf '   %s[ghcr]%s validating PAT via docker login\n' "$C_BOLD" "$C_RESET"

# Snapshot the docker config so we can leave the system the way we
# found it; an existing `docker login` for ghcr.io should still be
# valid when this script exits.
DOCKER_CFG="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
RESTORE_CFG=""
if [ -s "$DOCKER_CFG" ]; then
  RESTORE_CFG="$(mktemp)"
  cp -p "$DOCKER_CFG" "$RESTORE_CFG"
fi

if [ -n "${NEOHIVE_PAT:-}" ]; then
  PAT="$NEOHIVE_PAT"
  info "using PAT from NEOHIVE_PAT env var"
elif [ -s "$PAT_FILE" ]; then
  PAT="$(cat "$PAT_FILE")"
  info "using cached PAT at $PAT_FILE"
else
  printf '      %sFAIL%s  no PAT available - set NEOHIVE_PAT or run install.sh once to cache one.\n' \
    "$C_RED" "$C_RESET" >&2
  PAT_RESULT=1
  PAT=""
fi

PAT_RESULT=0
if [ -n "$PAT" ]; then
  info "PAT (masked): ${PAT:0:4}***${PAT: -4} (len=${#PAT})"
  if printf '%s' "$PAT" | docker login ghcr.io -u neohive-service --password-stdin >/dev/null 2>&1; then
    ok "docker login ghcr.io succeeded"
    # Also probe a manifest read to confirm read:packages on the image.
    if docker manifest inspect "$IMAGE:cpu" >/dev/null 2>&1; then
      ok "manifest read on $IMAGE:cpu OK (token has read:packages)"
    else
      warn "docker login OK but manifest inspect on $IMAGE:cpu failed - token may lack read:packages on the image"
      PAT_RESULT=1
    fi
  else
    printf '      %sFAIL%s  docker login ghcr.io was rejected - PAT revoked or wrong scope\n' \
      "$C_RED" "$C_RESET" >&2
    PAT_RESULT=1
  fi
fi

# Restore the prior docker config so we don't leave the system in a
# different login state than we found it.
if [ -n "$RESTORE_CFG" ] && [ -s "$RESTORE_CFG" ]; then
  cp -p "$RESTORE_CFG" "$DOCKER_CFG"
  rm -f "$RESTORE_CFG"
fi

# -- Summary -----------------------------------------------------------
separator
if [ "$LICENSE_RESULT" -eq 0 ] && [ "$PAT_RESULT" -eq 0 ]; then
  printf '   %sALL VALIDATIONS PASSED%s\n\n' "$C_GREEN$C_BOLD" "$C_RESET"
  exit 0
fi
[ "$LICENSE_RESULT" -ne 0 ] && printf '   %sFAIL%s license preflight\n' "$C_RED" "$C_RESET" >&2
[ "$PAT_RESULT" -ne 0 ] && printf '   %sFAIL%s PAT validation\n' "$C_RED" "$C_RESET" >&2
printf '\n'
exit 1
