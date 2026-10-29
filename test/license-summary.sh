#!/usr/bin/env bash
# A null or absent licence field must not end the install.
#
# Fields that do not apply come back null, and a healthy licence always sends
# "graceHoursRemaining":null. grep's miss became the assignment's status under
# pipefail, and errexit ended the script: after "ready" it took the closing
# block with the dashboard URL, and in read_license_file it exited before E306
# could name a licence file with no key in it.
#
# curl is stubbed and the licence file is a temp file, so nothing reaches the
# gateway, Keygen or Docker.

set -euo pipefail

cd "$(dirname "$0")/.."

FAILURES=0
fail() {
    printf '  FAIL  %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}
pass() { printf '  PASS  %s\n' "$1"; }

printf '\n=== license-summary: a healthy licence does not stop the install ===\n\n'

# Both nullable kinds: a null number and a null string.
export PAYLOAD='{"status":"valid","expiresAt":"2026-12-28T00:00:00.000Z","daysRemaining":67,"graceHoursRemaining":null,"graceHoursTotal":72,"holderName":null}'
if out=$(bash -c '
        NEOHIVE_LIB_ONLY=1
        # shellcheck source-path=SCRIPTDIR/..
        # shellcheck disable=SC1091
        source ./install.sh
        curl() { printf "%s" "$PAYLOAD"; }
        print_license_summary
    ' 2>&1); then
    pass "print_license_summary returned"
    case "$out" in
        *'License: valid'*) pass "it printed the licence line" ;;
        *) fail "no licence line in: $out" ;;
    esac
else
    fail "print_license_summary ended the install"
fi

printf '\n=== license-summary: a licence file with no key reaches E306 ===\n\n'

LICENSE_DIR="$(mktemp -d)"
trap 'rm -rf "$LICENSE_DIR"' EXIT
printf '%s' '{"meta":{"x":1}}' > "$LICENSE_DIR/license.json"

# read_license_file is called bare, so a grep miss there exited before the
# diagnostic. jq returning empty still falls through to the grep.
out=$(bash -c '
        NEOHIVE_LIB_ONLY=1
        # shellcheck source-path=SCRIPTDIR/..
        # shellcheck disable=SC1091
        source ./install.sh
        read_license_file "$1"
    ' _ "$LICENSE_DIR/license.json" 2>&1 || true)
case "$out" in
    *E306*) pass "it named the missing key" ;;
    *) fail "exited without E306, printed: $out" ;;
esac

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'license-summary: all checks passed\n'
else
    printf 'license-summary: %d check(s) failed\n' "$FAILURES" >&2
    exit 1
fi
