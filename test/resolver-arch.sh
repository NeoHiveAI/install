#!/usr/bin/env bash
# Hermetic regression test for architecture-aware tag resolution.
#
# NeoHive's FLOATING tags (:cpu, :latest) are multi-arch manifest lists,
# so stage-1 resolution needs no arch suffix. But VERSIONED tags are
# published per-arch on Docker Hub: amd64 as v<X>-cpu and arm64 as
# v<X>-cpu-arm64 (there is no multi-arch versioned manifest). If stage-1's
# floating pull ever fails (interrupted download, transient network, or a
# release window where the floating tag lags the versioned ones), the
# stage-2 versioned fallback must append the arch suffix - otherwise it
# enumerates amd64-only v<X>-cpu tags on an arm64 host, every pull misses,
# and the installer wrongly reports "no compatible image" on a platform
# that has images.
#
# This test drives resolve_with_suffix with a stubbed registry (canned
# Docker Hub JSON) and a stubbed puller that models real per-arch pull
# behaviour, forcing stage-1 to miss so stage-2 is exercised. No Docker
# daemon, no network, no credentials.

# NEOHIVE_LIB_ONLY / UNAME_M / BACKEND are read by the sourced install.sh;
# the source is not followed (SC1091 disabled) so they are misflagged as
# unused. This file-level suppression must precede the first command to
# apply script-wide.
# shellcheck disable=SC2034
set -euo pipefail

cd "$(dirname "$0")/.."

NEOHIVE_LIB_ONLY=1
# shellcheck disable=SC1091
source ./install.sh

FAILURES=0
assert_eq() {
  # assert_eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  PASS  %s (= %s)\n' "$1" "$3"
  else
    printf '  FAIL  %s: expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# Canned Docker Hub tag listing. Mirrors the real publish layout: floating
# multi-arch tags, per-arch versioned stable tags, and an arm64 RC that
# must be filtered out by the pre-release guard.
CANNED_TAGS_JSON='{"count":8,"results":[
{"name":"latest"},{"name":"cpu"},
{"name":"v1.6.3-cpu"},{"name":"v1.6.3-cpu-arm64"},
{"name":"v1.6.3-rc1-cpu-arm64"},
{"name":"v1.6.2-cpu"},{"name":"v1.6.2-cpu-arm64"}
]}'

# Stub the registry list call used by list_versioned_tags. install.sh calls
# `curl` unqualified, so this shell function shadows it for the test.
# shellcheck disable=SC2317
curl() { printf '%s' "$CANNED_TAGS_JSON"; }

# Stub the puller to model real `docker pull` arch behaviour:
#   - floating tags (no v<N> prefix) simulated as UNAVAILABLE, forcing
#     the resolver into the stage-2 versioned fallback under test;
#   - versioned tags pull only when the tag's arch matches SIM_ARCH.
# shellcheck disable=SC2317
try_pull_tag() {
  local tag="$1"
  # Defense in depth, mirroring production: never pull a pre-release.
  if printf '%s' "$tag" | grep -qE -- "$PRERELEASE_TAG_PATTERN"; then
    return 1
  fi
  case "$tag" in
    v[0-9]*) : ;;   # versioned - fall through to arch check
    *)       return 1 ;;  # floating - simulate stage-1 miss
  esac
  case "$SIM_ARCH" in
    arm64|aarch64) case "$tag" in *-arm64) return 0 ;; *) return 1 ;; esac ;;
    *)             case "$tag" in *-arm64) return 1 ;; *) return 0 ;; esac ;;
  esac
}

# Resolve for a simulated host architecture and echo the settled tag.
resolve_for_arch() {
  SIM_ARCH="$1"
  UNAME_M="$1"
  BACKEND=cpu
  RESOLVED_TAG=""
  resolve_with_suffix "" >/dev/null 2>&1 || true
  printf '%s' "$RESOLVED_TAG"
}

printf '\n=== resolver-arch: stage-2 versioned fallback is arch-aware ===\n\n'

# arm64: the fallback must land on the newest stable arm64 build, NOT an
# amd64-only v<X>-cpu tag, and NOT the filtered arm64 RC.
assert_eq "arm64 falls back to newest stable arm64 versioned tag" \
  "v1.6.3-cpu-arm64" "$(resolve_for_arch arm64)"

# aarch64 is the Linux spelling of the same architecture.
assert_eq "aarch64 falls back to newest stable arm64 versioned tag" \
  "v1.6.3-cpu-arm64" "$(resolve_for_arch aarch64)"

# amd64 is unchanged: it must still resolve the plain v<X>-cpu tag.
assert_eq "x86_64 falls back to newest stable amd64 versioned tag" \
  "v1.6.3-cpu" "$(resolve_for_arch x86_64)"

printf '\n=== resolver-arch: arch_tag_suffix mapping ===\n\n'
assert_eq "arm64 -> -arm64"   "-arm64" "$(UNAME_M=arm64   arch_tag_suffix)"
assert_eq "aarch64 -> -arm64" "-arm64" "$(UNAME_M=aarch64 arch_tag_suffix)"
assert_eq "x86_64 -> (empty)" ""       "$(UNAME_M=x86_64  arch_tag_suffix)"
assert_eq "amd64 -> (empty)"  ""       "$(UNAME_M=amd64   arch_tag_suffix)"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'resolver-arch: all assertions passed\n'
else
  printf 'resolver-arch: %d assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi
