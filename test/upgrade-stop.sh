#!/usr/bin/env bash
# Hermetic regression test for how an upgrade removes the old container.
#
# The installer used to remove it with `docker rm -f` alone, which kills the
# server outright. The server never got to free its licence seat, so on a
# one-machine licence the new container could fail to start with
# MACHINE_LIMIT_EXCEEDED. It also cut off running syncs and left its databases
# unclosed. replace_existing_container now asks the server to stop first and
# removes the container either way.
#
# docker is stubbed as a shell function that records each call. No Docker
# daemon, no network.

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
    printf '  PASS  %s\n' "$1"
  else
    printf '  FAIL  %s: expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

CALLS=""
# SIM_EXISTS=1 makes `docker ps -a` list the container. SIM_STOP_FAILS=1 makes
# `docker stop` fail, as it does when the daemon cannot signal the container.
# shellcheck disable=SC2317
docker() {
  case "$1" in
    ps)
      [ "${SIM_EXISTS:-0}" = "1" ] && printf '%s\n' "$CONTAINER_NAME"
      return 0
      ;;
    stop)
      CALLS="${CALLS}stop:$2=$3:$4;"
      [ "${SIM_STOP_FAILS:-0}" = "1" ] && return 1
      return 0
      ;;
    rm)
      CALLS="${CALLS}rm:$2:$3;"
      return 0
      ;;
  esac
}
# shellcheck disable=SC2317
info() { :; }

printf '\nreplace_existing_container stops the server before removing it\n'

CALLS=""
SIM_EXISTS=1 replace_existing_container
assert_eq "a running container is stopped with a timeout, then removed" \
  "stop:--time=30:neohive;rm:-f:neohive;" "$CALLS"

CALLS=""
SIM_EXISTS=1 SIM_STOP_FAILS=1 replace_existing_container
assert_eq "a container whose stop fails is still removed" \
  "stop:--time=30:neohive;rm:-f:neohive;" "$CALLS"

CALLS=""
SIM_EXISTS=0 replace_existing_container
assert_eq "a fresh install with no container touches nothing" "" "$CALLS"

printf '\nthe upgrade step goes through replace_existing_container\n'

# The cases above only prove the function is right. These read install.sh as
# text, so putting a bare `docker rm -f` back into the main flow fails here.
# The function body is the one allowed place for that removal.
main_flow="$(sed -n '/^# Main flow$/,$p' ./install.sh)"
assert_eq "the main flow calls replace_existing_container" \
  "1" "$(printf '%s\n' "$main_flow" | grep -c '^replace_existing_container$')"
# The single quotes are deliberate: the search is for the literal text
# `$CONTAINER_NAME` as it is written in install.sh.
# shellcheck disable=SC2016
assert_eq "the main flow never removes the container itself" \
  "0" "$(printf '%s\n' "$main_flow" | grep -cF 'docker rm -f "$CONTAINER_NAME"')"

printf '\n'
if [ "$FAILURES" -gt 0 ]; then
  printf 'upgrade-stop: %d assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf 'upgrade-stop: all assertions passed\n'
