#!/usr/bin/env bash
# Prove logs.sh's redaction filter on the shapes a diagnostics bundle really
# contains, without Docker. Sources logs.sh as a library and pushes fixture
# lines through redact():
#
#   - must be masked: NEOHIVE_LICENSE_KEY as docker inspect prints it (JSON
#     array element and plain env form), an *_AUTH_SECRET, a bearer token,
#     GitHub tokens, an image digest, and the licence literal appearing in
#     free text (the last line of defence);
#   - must survive: non-secret MEMVEC_* settings, hive UUIDs, hostnames,
#     ports - support needs these, and over-redaction hides the fault.
#
# No network, no Docker. Exit 0 when every expectation holds.

set -euo pipefail

cd "$(dirname "$0")/.."

NEOHIVE_LIB_ONLY=1
# shellcheck disable=SC1091
source ./logs.sh

KEY="ABCD-1234-EFGH-5678-KEY9"
LICENSE_LITERAL="$KEY"
AUTH_SECRET="s3cr3tvalue_do_not_leak"
BEARER="eyJhbGciOiJIUzI1NiJ9.payload.sig"
GHP="ghp_abcdefghijklmnopqrstuvwxyz0123456789"
PAT="github_pat_11ABCDEFG0123456789abcdefghijklmnop"
DIGEST="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

INPUT="$(printf '%s\n' \
  "\"NEOHIVE_LICENSE_KEY=$KEY\"," \
  "NEOHIVE_LICENSE_KEY=$KEY" \
  "\"Env\": [\"MEMVEC_QUERY_WORKER_PORT=50051\", \"COGNITIVE_MEMORY_AUTH_SECRET=$AUTH_SECRET\"]," \
  "authorization: Bearer $BEARER" \
  "token $GHP and $PAT" \
  "\"Image\": \"sha256:$DIGEST\"" \
  "the key leaked here: $KEY end" \
  "\"licenseKey\": \"$KEY\"" \
  "MEMVEC_QUERY_WORKER_HOST=host.docker.internal keep-host" \
  "hive id 0d7aece3-77de-4412-8ce2-06a8c460ca88 keep-uuid" \
  "MEMVEC_QUERY_WORKER_PORT=50051 keep-port" \
  "Job completed for hive keep-plain-log-line")"

OUTPUT="$(printf '%s\n' "$INPUT" | redact)"

pass=0; failures=0
must_not_contain() {
  if printf '%s' "$OUTPUT" | grep -qF -- "$1"; then
    printf 'FAIL leaked:   %s\n' "$2" >&2; failures=$((failures + 1))
  else
    printf 'ok   masked:   %s\n' "$2"; pass=$((pass + 1))
  fi
}
must_contain() {
  if printf '%s' "$OUTPUT" | grep -qF -- "$1"; then
    printf 'ok   kept:     %s\n' "$2"; pass=$((pass + 1))
  else
    printf 'FAIL over-redacted: %s\n' "$2" >&2; failures=$((failures + 1))
  fi
}

must_not_contain "$KEY"          "licence key (every occurrence)"
must_not_contain "$AUTH_SECRET"  "COGNITIVE_MEMORY_AUTH_SECRET value"
must_not_contain "$BEARER"       "bearer token"
must_not_contain "$GHP"          "GitHub ghp_ token"
must_not_contain "$PAT"          "GitHub fine-grained PAT"
must_not_contain "$DIGEST"       "64-hex image digest"

must_contain "NEOHIVE_LICENSE_KEY=[REDACTED]"          "licence var name stays, value replaced"
must_contain "COGNITIVE_MEMORY_AUTH_SECRET=[REDACTED]" "auth secret name stays, value replaced"
must_contain "\"licenseKey\": \"[REDACTED]"            "camelCase JSON key handled"
must_contain "MEMVEC_QUERY_WORKER_HOST=host.docker.internal" "non-secret setting untouched"
must_contain "0d7aece3-77de-4412-8ce2-06a8c460ca88"    "hive UUID untouched"
must_contain "MEMVEC_QUERY_WORKER_PORT=50051 keep-port" "port untouched"
must_contain "Job completed for hive keep-plain-log-line" "plain log line untouched"

# Empty LICENSE_LITERAL must be a no-op path, not a broken sed expression.
LICENSE_LITERAL=""
printf 'plain\n' | redact | grep -qx 'plain' && { printf 'ok   no-literal path\n'; pass=$((pass + 1)); } \
  || { printf 'FAIL no-literal path\n' >&2; failures=$((failures + 1)); }

printf '\n%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ]
