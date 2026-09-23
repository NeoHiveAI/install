#!/usr/bin/env bash
# Hermetic regression test for the Metal worker health probe.
#
# metal_worker_health_ok decides whether embeddings run on the native worker or
# in-container on CPU. It used to be `nc -z` alone, so any process holding the
# port read as a healthy worker: the install claimed "Metal worker active", the
# gateway was pointed at a port no worker had bound, and every embed failed
# `14 UNAVAILABLE` with no fallback. Found by MAN-INSTALL-02 case 4 on rc.8.
#
# Nothing here is a worker: it drives the accept-or-decline branches of a shell
# function. nc and sleep are shadowed and the bundle is a stub, so it needs no
# socket, launchd, worker or model, and passes on a Linux runner and a Mac alike.

# The stubs are called only by the sourced install.sh, which shellcheck cannot
# see, so they read as unused and unreachable. SC2016 is for the stub node
# script, which writes a literal `$1` on purpose. Must precede the first command.
# shellcheck disable=SC2016,SC2034,SC2317
set -euo pipefail

cd "$(dirname "$0")/.."

NEOHIVE_LIB_ONLY=1
# shellcheck source-path=SCRIPTDIR/..  # the cd above happens at run time;
# this is where shellcheck should look when it reads the source line
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

# PORT_LISTENING: whether anything holds the port at all (phase 1).
PORT_LISTENING=1
nc() { [ "$PORT_LISTENING" = "1" ]; }

# The retry budget, made instant. The loop always runs one attempt, so zero
# still reaches every branch.
sleep() { :; }
export NEOHIVE_METAL_WORKER_HEALTH_BUDGET_S=0

# `BUDGET=60 out="$(...)"` looks scoped but is two plain assignments, and a
# leaked budget makes a later decline case spin on the real clock (sleep is a
# no-op here) and look hung.
with_budget() {
  # with_budget <seconds> <port>
  NEOHIVE_METAL_WORKER_HEALTH_BUDGET_S="$1"
  metal_worker_health_ok "$2"
  local rc=$?
  NEOHIVE_METAL_WORKER_HEALTH_BUDGET_S=0
  return $rc
}

# A stub worker bundle. `node` execs the "healthcheck", which is a script whose
# exit status the test sets, so phase 2 is driven without a worker or a model.
METAL_WORKER_ROOT="$SANDBOX/metal-worker"
mkdir -p "$METAL_WORKER_ROOT/current/bin" "$METAL_WORKER_ROOT/current/lib"
printf '#!/usr/bin/env bash\nexec bash "$1"\n' > "$METAL_WORKER_ROOT/current/bin/node"
chmod +x "$METAL_WORKER_ROOT/current/bin/node"
set_healthcheck() {
  # set_healthcheck <exit-code> <message>
  printf '#!/usr/bin/env bash\necho "%s"\nexit %s\n' "$2" "$1" \
    > "$METAL_WORKER_ROOT/current/lib/healthcheck.cjs"
}
HEALTHY='[healthcheck] ok - embedded in 154ms (dim 768, model nomic-ai/nomic-embed-text-v1.5)'
UNHEALTHY='[healthcheck] embed failed - unhealthy: 14 UNAVAILABLE: No connection established'

# Fails the first <n> calls, then succeeds. The counter is a file because the
# healthcheck runs inside $(...), so a variable it set would be discarded.
ATTEMPTS="$SANDBOX/attempts"
set_healthcheck_failing_first() {
  # set_healthcheck_failing_first <n>
  : > "$ATTEMPTS"
  cat > "$METAL_WORKER_ROOT/current/lib/healthcheck.cjs" <<STUB
#!/usr/bin/env bash
echo x >> "$ATTEMPTS"
if [ "\$(wc -l < "$ATTEMPTS")" -le "$1" ]; then
  echo '$UNHEALTHY'
  exit 1
fi
echo '$HEALTHY'
exit 0
STUB
}
attempts_made() { wc -l < "$ATTEMPTS" | tr -d ' '; }

printf '\n=== a worker that answers a health embed is accepted ===\n\n'
PORT_LISTENING=1
set_healthcheck 0 "$HEALTHY"
rc=0
out="$(metal_worker_health_ok 50051)" || rc=$?
assert_eq "a healthy worker is accepted" "0" "$rc"
assert_eq "nothing is printed on success" "" "$out"

printf '\n=== a worker that answers on a later attempt is retried, not written off ===\n\n'
# Guards the retry branch: every other case runs at a zero budget, so nothing
# else would notice a slow-starting worker being dropped to CPU.
PORT_LISTENING=1
set_healthcheck_failing_first 2
rc=0
out="$(with_budget 60 50051)" || rc=$?
assert_eq "it keeps trying while the budget allows" "0" "$rc"
assert_eq "it stopped as soon as one succeeded" "3" "$(attempts_made)"
assert_eq "nothing is printed on success" "" "$out"

printf '\n=== the budget bounds the wait rather than the attempt count ===\n\n'
PORT_LISTENING=1
set_healthcheck 1 "$UNHEALTHY"
rc=0
out="$(with_budget 0 50051)" || rc=$?
assert_eq "a zero budget declines after a single attempt" "1" "$rc"

printf '\n=== the health budget is validated, not trusted ===\n\n'
# Arithmetic reads a non-numeric value as 0, which would silently cut phase 2 to
# a single attempt. warn goes to stderr, so only the number reaches stdout.
assert_eq "an unset budget defaults to 90" "90" \
  "$(unset NEOHIVE_METAL_WORKER_HEALTH_BUDGET_S; metal_worker_health_budget)"
assert_eq "a valid budget is used as given" "30" \
  "$(NEOHIVE_METAL_WORKER_HEALTH_BUDGET_S=30 metal_worker_health_budget 2>/dev/null)"
assert_eq "zero is allowed and means one attempt" "0" \
  "$(NEOHIVE_METAL_WORKER_HEALTH_BUDGET_S=0 metal_worker_health_budget 2>/dev/null)"
assert_eq "a typo falls back rather than becoming 0" "90" \
  "$(NEOHIVE_METAL_WORKER_HEALTH_BUDGET_S=9O metal_worker_health_budget 2>/dev/null)"
assert_contains "and it says so" "must be a non-negative integer" \
  "$(NEOHIVE_METAL_WORKER_HEALTH_BUDGET_S=9O metal_worker_health_budget 2>&1 >/dev/null)"

printf '\n=== a listener that cannot embed is declined ===\n\n'
PORT_LISTENING=1
set_healthcheck 1 "$UNHEALTHY"
rc=0
out="$(metal_worker_health_ok 50051)" || rc=$?
assert_eq "a TCP accept alone is not proof of a worker" "1" "$rc"
assert_contains "it names the port it declined" "127.0.0.1:50051" "$out"
assert_contains "it reports the health embed failure" "14 UNAVAILABLE" "$out"

printf '\n=== a port nothing is listening on is declined ===\n\n'
PORT_LISTENING=0
set_healthcheck 0 "$HEALTHY"
rc=0
out="$(metal_worker_health_ok 50051)" || rc=$?
assert_eq "no listener is declined" "1" "$rc"
assert_contains "it says nothing was listening" "nothing is listening" "$out"

printf '\n=== a bundle with no healthcheck is declined ===\n\n'
PORT_LISTENING=1
rm -f "$METAL_WORKER_ROOT/current/lib/healthcheck.cjs"
rc=0
out="$(metal_worker_health_ok 50051)" || rc=$?
assert_eq "an unverifiable bundle is declined, not trusted" "1" "$rc"
assert_contains "it names the healthcheck it wanted" "healthcheck.cjs" "$out"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  echo "metal-worker-probe: all assertions passed"
else
  echo "metal-worker-probe: $FAILURES assertion(s) failed" >&2
  exit 1
fi
