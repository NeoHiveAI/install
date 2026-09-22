#!/usr/bin/env bash
# Hermetic regression test for loading the Metal worker's launch agent.
#
# `launchctl bootout` returns before launchd has finished unloading, so a
# `bootstrap` issued straight after it can fail with "Bootstrap failed: 5:
# Input/output error" while the plist is perfectly valid. setup_metal_worker
# treats a failed bootstrap as "no native worker" and downgrades the install to
# in-container CPU embedding, so a single attempt turns that timing blip into a
# silent permanent downgrade: the customer's second install of the same build
# succeeds and nothing explains why the first did not.
#
# The failure modes defended here are all quiet ones:
#
#   1. A transient bootstrap failure must be retried, not reported as a broken
#      worker.
#   2. A permanent failure must still give up, and must surface the launchctl
#      error so the cause is named rather than guessed.
#   3. A loaded agent must be kickstarted, so the worker is running when the
#      installer's reachability probe checks the port moments later.
#
# launchctl, sleep and id are shadowed by shell functions (install.sh calls
# them unqualified), so this needs no launchd and runs on any POSIX host
# including Linux CI.

# NEOHIVE_LIB_ONLY is read by the sourced install.sh; the source is not
# followed (SC1091 disabled) so it is misflagged as unused. The launchctl,
# sleep and id stubs are called only by the sourced code, which shellcheck
# cannot see, so their bodies are misflagged as unreachable. This file-level
# suppression must precede the first command to apply script-wide.
# shellcheck disable=SC2034,SC2317
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
assert_contains() {
  # assert_contains <label> <needle> <haystack>
  case "$3" in
    *"$2"*) printf '  PASS  %s\n' "$1" ;;
    *)
      printf '  FAIL  %s: [%s] does not contain [%s]\n' "$1" "$3" "$2" >&2
      FAILURES=$((FAILURES + 1))
      ;;
  esac
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
CALLS="$SANDBOX/launchctl.calls"
COUNT="$SANDBOX/bootstrap.count"

# BOOTSTRAP_FAILURES: 0 = always succeed; <n> = fail the first n bootstrap
# calls (models launchd's teardown race); "always" = never load.
BOOTSTRAP_FAILURES=0

# The counter lives in a file, not a variable: bootstrap_launch_agent captures
# launchctl's output with $(...), so the stub runs in a subshell and any
# variable it set would be discarded when that subshell exits.
launchctl() {
  printf '%s\n' "$*" >>"$CALLS"
  if [ "${1:-}" = "bootstrap" ] && [ "$BOOTSTRAP_FAILURES" != "0" ]; then
    local n
    n="$(cat "$COUNT")"
    n=$((n + 1))
    printf '%s' "$n" >"$COUNT"
    if [ "$BOOTSTRAP_FAILURES" = "always" ] || [ "$n" -le "$BOOTSTRAP_FAILURES" ]; then
      printf 'Bootstrap failed: 5: Input/output error\n' >&2
      return 5
    fi
  fi
  return 0
}

# The retry backoff, made instant.
sleep() { :; }
id() { printf '501'; }

reset_sandbox() {
  : >"$CALLS"
  printf '0' >"$COUNT"
}
calls() { grep -Ec -- "$1" "$CALLS" || true; }

PLIST="$SANDBOX/com.neohive.metal-worker.plist"
LABEL="com.neohive.metal-worker"
: >"$PLIST"

printf '\n=== a clean bootstrap loads and starts the agent ===\n\n'
reset_sandbox
BOOTSTRAP_FAILURES=0
rc=0
out="$(bootstrap_launch_agent "$LABEL" "$PLIST")" || rc=$?
assert_eq "a first-try bootstrap reports success" "0" "$rc"
assert_eq "it is bootstrapped exactly once" "1" "$(calls '^bootstrap')"
assert_eq "the agent is kickstarted so it is running for the port probe" \
  "1" "$(calls '^kickstart')"
assert_eq "nothing is printed on success" "" "$out"

printf '\n=== launchd teardown race: a flaky bootstrap still ends up loaded ===\n\n'
# Two rejections then success. Giving up here is what silently downgrades a
# perfectly good Apple Silicon install to in-container CPU embedding.
reset_sandbox
BOOTSTRAP_FAILURES=2
rc=0
out="$(bootstrap_launch_agent "$LABEL" "$PLIST")" || rc=$?
assert_eq "a transient failure is retried through to success" "0" "$rc"
assert_eq "it retries rather than giving up on the first error" \
  "3" "$(calls '^bootstrap')"
assert_eq "the agent ends up started" "1" "$(calls '^kickstart')"

printf '\n=== a permanent failure gives up and says why ===\n\n'
# A malformed plist or a program that cannot execute fails every attempt. The
# retry must not become an infinite wait, and the launchctl error is the only
# thing that tells the customer which of those it was.
reset_sandbox
BOOTSTRAP_FAILURES=always
rc=0
out="$(bootstrap_launch_agent "$LABEL" "$PLIST")" || rc=$?
assert_eq "a permanent failure reports failure" "1" "$rc"
assert_eq "it stops after a bounded number of attempts" "5" "$(calls '^bootstrap')"
assert_eq "a failed load is never kickstarted" "0" "$(calls '^kickstart')"
assert_contains "the launchctl error is handed back to the caller" \
  "Bootstrap failed: 5" "$out"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'All launch-agent assertions passed.\n'
  exit 0
fi
printf '%s assertion(s) FAILED.\n' "$FAILURES" >&2
exit 1
