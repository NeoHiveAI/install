#!/usr/bin/env bash
# Hermetic regression test for the empty-resolution diagnosis.
#
# When tag resolution comes up empty, the installer must distinguish two
# very different failures:
#   - a genuinely missing image / unreachable registry  -> E502
#   - a compatible image that exists but whose pull did not finish
#     (interrupted Ctrl-C download, or a transient network drop
#     mid-transfer)                                       -> E503
#
# Historically both collapsed into a single misleading E502
# "no compatible image found ... check connectivity", which told an
# arm64 user their platform was unsupported when in fact the image was
# right there and they had merely aborted a slow download.
#
# docker manifest inspect is a metadata-only probe (no layers move), so
# diagnose_empty_resolution can cheaply ask "does an image for this
# platform actually exist?" before choosing the error. This test stubs
# that probe and the fail() helper - no Docker daemon, no network.

# NEOHIVE_LIB_ONLY is read by the sourced install.sh; the source is not
# followed (SC1091 disabled) so it is misflagged as unused. This file-level
# suppression must precede the first command to apply script-wide.
# shellcheck disable=SC2034
set -euo pipefail

cd "$(dirname "$0")/.."

NEOHIVE_LIB_ONLY=1
# shellcheck source-path=SCRIPTDIR/..  # the cd above happens at run time;
# this is where shellcheck should look when it reads the source line
# shellcheck disable=SC1091
source ./install.sh

FAILURES=0
assert_eq() {
  if [ "$2" = "$3" ]; then
    printf '  PASS  %s (= %s)\n' "$1" "$3"
  else
    printf '  FAIL  %s: expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# Stub `docker manifest inspect <tag>`. diagnose_empty_resolution now greps
# the emitted manifest list for a layer matching the host arch (rather than
# trusting the command's exit status), so the stub must emit a list whose
# platform layers match the real published layout. SIM_MANIFEST=reachable
# emits the list and succeeds; anything else fails like an absent/unreachable
# tag. SIM_LAYERS (default "amd64 arm64") controls which arch layers appear,
# so a test can model a list that is present but lacks the host's arch.
# shellcheck disable=SC2317
docker() {
  case "${SIM_MANIFEST:-missing}" in
    reachable) : ;;
    *)         return 1 ;;
  esac
  local arch layers
  read -ra layers <<<"${SIM_LAYERS:-amd64 arm64}"
  printf '{\n   "manifests": [\n'
  for arch in "${layers[@]}"; do
    printf '      { "platform": { "architecture": "%s", "os": "linux" } },\n' "$arch"
  done
  # A buildx attestation layer (architecture "unknown") always trails the
  # real ones on Docker Hub; include it so the grep must skip it.
  printf '      { "platform": { "architecture": "unknown", "os": "unknown" } }\n   ]\n}\n'
}

# Stub fail() to behave like production (emit the code, stop) but in a
# capturable way: print the code to stdout and exit the subshell. Running
# diagnose_empty_resolution inside $() then yields the first code emitted.
# shellcheck disable=SC2317
fail() { printf '%s' "$1"; exit 1; }

emitted_code() {
  # emitted_code <reachable|missing> <host-arch> [layers]
  # The subshell exits via the stubbed fail(); `|| true` keeps `set -e`
  # from aborting the harness. shellcheck's reachability pass flags the
  # trailing `true` (SC2317) because it cannot see the stub exits.
  # shellcheck disable=SC2317
  ( SIM_MANIFEST="$1" UNAME_M="$2" SIM_LAYERS="${3:-amd64 arm64}" \
    diagnose_empty_resolution 2>/dev/null || true )
}

printf '\n=== pull-diagnosis: empty resolution picks the right error code ===\n\n'

# Supported host arch + a manifest list that carries its layer: the empty
# resolution is an incomplete pull, not a missing image -> E503.
assert_eq "reachable list, arm64 host -> E503" \
  "E503" "$(emitted_code reachable arm64)"

assert_eq "reachable list, x86_64 host -> E503" \
  "E503" "$(emitted_code reachable x86_64)"

# Unsupported host arch (nothing is ever built for it): the :cpu/:latest
# list exists but has no matching layer, so the pull can never succeed.
# We must NOT tell the user to "re-run to resume" - restore E502. This is
# the regression the arch-agnostic `docker manifest inspect` check caused.
assert_eq "reachable list, unsupported host arch (ppc64le) -> E502" \
  "E502" "$(emitted_code reachable ppc64le)"

# Grep-level guard: a supported host whose arch layer is genuinely absent
# from the list must also fall to E502, proving diagnosis filters by layer
# rather than by the command's exit status.
assert_eq "reachable list missing the host arch layer -> E502" \
  "E502" "$(emitted_code reachable arm64 amd64)"

assert_eq "image genuinely absent / registry unreachable -> E502" \
  "E502" "$(emitted_code missing x86_64)"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'pull-diagnosis: all assertions passed\n'
else
  printf 'pull-diagnosis: %d assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi
