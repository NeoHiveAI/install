#!/usr/bin/env bash
# Build a real diagnostics bundle with logs.sh against fakes and prove what
# ends up inside it. A PATH shim replaces docker, launchctl, uname, nc and
# curl with fakes that answer like an Apple Silicon machine running NeoHive
# with the Metal worker, and every fake output is salted with the licence
# key in the shapes it could really appear: the NEOHIVE_LICENSE_KEY env in
# docker inspect, a log line that printed it, a worker log that printed it.
# The cached licence-key file in the temporary HOME holds the same value.
#
# Then the archive is extracted and:
#   - the licence key must appear NOWHERE in it (the strongest check);
#   - the expected files must exist and be non-empty;
#   - non-secret settings must survive redaction (over-redaction hides
#     the fault support is looking for);
#   - license.txt must record presence only, never the value;
#   - the bundle must not include the licence-key file or any database.
#
# A last case pipes the script into bash with no file behind it, the shape
# `curl ... | bash` produces, because the build above hands bash a path.
#
# No network, no Docker. Exit 0 when every expectation holds.

set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT="$PWD/logs.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/neohive-logs-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SHIM="$WORK/bin"
OUT_DIR="$WORK/out"
mkdir -p "$SHIM" "$OUT_DIR"

KEY="LIC-TEST-9F3A-77BB-KEY-VALUE"
export FAKE_KEY="$KEY"

# -- Fakes ----------------------------------------------------------------
cat > "$SHIM/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info) echo "Server Version: 27.0.0"; exit 0 ;;
  --version) echo "Docker version 27.0.0"; exit 0 ;;
  ps) echo "neohive"; exit 0 ;;
  logs)
    echo "2026-09-14T09:00:00Z gateway listening on 3577"
    echo "2026-09-14T09:00:01Z env NEOHIVE_LICENSE_KEY=$FAKE_KEY loaded"
    echo "2026-09-14T09:00:02Z Job completed for hive 0d7aece3-77de-4412-8ce2-06a8c460ca88"
    exit 0 ;;
  inspect)
    if [ "$2" = "--format" ]; then echo "neohivedev/neohive:cpu sha256:abc"; exit 0; fi
    cat <<JSON
[{"Config":{"Image":"neohivedev/neohive:cpu","Env":["NEOHIVE_LICENSE_KEY=$FAKE_KEY","MEMVEC_QUERY_WORKER_HOST=host.docker.internal","MEMVEC_QUERY_WORKER_PORT=50051"]}}]
JSON
    exit 0 ;;
  volume) echo '[{"Name":"neohive-data","Mountpoint":"/var/lib/docker/volumes/neohive-data/_data"}]'; exit 0 ;;
  exec) echo "1.2G /app/data"; echo "/app/data/hives/h1/cognitive-memory.db"; exit 0 ;;
  top) echo "PID USER COMMAND"; echo "1 root node bytecode-entry.cjs"; exit 0 ;;
esac
exit 0
EOF
cat > "$SHIM/launchctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '123\t0\tcom.neohive.metal-worker\n456\t0\tcom.neohive.metal-worker-watchdog\n' ;;
  print) echo "state = running"; echo "last exit code = 0" ;;
esac
exit 0
EOF
cat > "$SHIM/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -m) echo arm64 ;; -a) echo "Darwin test 25.6.0 arm64" ;; *) echo Darwin ;; esac
EOF
cat > "$SHIM/nc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"status":"ok","version":"1.7.0","workers":1}'
exit 0
EOF
chmod +x "$SHIM"/*

# -- Seeded HOME ---------------------------------------------------------
export HOME="$WORK/home"
mkdir -p "$HOME/.cache/neohive" "$HOME/.neohive/metal-worker/current/bin" "$HOME/.neohive/logs" "$HOME/Library/LaunchAgents"
printf '%s\n' "$KEY" > "$HOME/.cache/neohive/license-key"
echo "fingerprint-uuid-1234" > "$HOME/.cache/neohive/machine-id"
echo "v1.7.0" > "$HOME/.neohive/metal-worker/current/VERSION"
: > "$HOME/.neohive/metal-worker/current/bin/node"
printf 'worker started on 50051\nlicense %s accepted\n' "$KEY" > "$HOME/.neohive/logs/metal-worker.log"
printf 'nothing wrong\n' > "$HOME/.neohive/logs/metal-worker.err.log"
printf '<plist><dict><key>Label</key><string>com.neohive.metal-worker</string></dict></plist>\n' > "$HOME/Library/LaunchAgents/com.neohive.metal-worker.plist"
printf '<plist/>\n' > "$HOME/Library/LaunchAgents/com.neohive.metal-worker-watchdog.plist"
unset XDG_CACHE_HOME
export NEOHIVE_LICENSE_KEY="$KEY"   # exported in the shell, must be blanked in env.txt

# -- Run -------------------------------------------------------------------
PATH="$SHIM:$PATH" bash "$SCRIPT" --out "$OUT_DIR" --tail 50 >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; echo "logs.sh failed"; exit 1; }

ARCHIVE="$(find "$OUT_DIR" -name 'neohive-diag-*.tar.gz' | head -1)"
[ -n "$ARCHIVE" ] || { echo "no archive produced"; cat "$WORK/run.log"; exit 1; }
EXTRACT="$WORK/extract"
mkdir -p "$EXTRACT"
tar -C "$EXTRACT" -xzf "$ARCHIVE"
BUNDLE="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -1)"

pass=0; failures=0
check() {
  local desc="$1"; shift
  if "$@"; then printf 'ok   %s\n' "$desc"; pass=$((pass + 1))
  else printf 'FAIL %s\n' "$desc" >&2; failures=$((failures + 1)); fi
}
bundle_has() { test -s "$BUNDLE/$1"; }
bundle_lacks() { test ! -e "$BUNDLE/$1"; }
in_bundle() { grep -rqF -- "$1" "$BUNDLE"; }
in_file() { grep -qF -- "$2" "$BUNDLE/$1"; }

printf '\n-- the key must appear nowhere\n'
# shellcheck disable=SC2016  # bash -c takes its args positionally as "$1";
# the single quotes are the point
check "licence key absent from every file"       bash -c '! grep -rqF -- "$1" "$2"' _ "$KEY" "$BUNDLE"
check "inspect env value replaced"               in_file container/docker-inspect.json 'NEOHIVE_LICENSE_KEY=[REDACTED]'
check "container log line replaced"              in_file container/docker-logs.txt 'NEOHIVE_LICENSE_KEY=[REDACTED]'
check "worker log free-text occurrence replaced" in_file metal-worker/logs/metal-worker.log '[REDACTED]'
check "shell env value replaced"                 in_file env.txt 'NEOHIVE_LICENSE_KEY=[REDACTED]'

printf '\n-- expected contents\n'
check "system.txt"                 bundle_has system.txt
check "docker-info.txt"            bundle_has docker-info.txt
check "docker-ps.txt"              bundle_has docker-ps.txt
check "container/docker-logs.txt"  bundle_has container/docker-logs.txt
check "container/docker-inspect"   bundle_has container/docker-inspect.json
check "container/health.json"      bundle_has container/health.json
check "container/data-usage.txt"   bundle_has container/data-usage.txt
check "container/image.txt"        bundle_has container/image.txt
check "metal-worker/version.txt"   bundle_has metal-worker/version.txt
check "metal-worker/launchctl"     bundle_has metal-worker/launchctl-list.txt
check "metal-worker worker plist"  bundle_has metal-worker/com.neohive.metal-worker.plist
check "metal-worker/port-check"    bundle_has metal-worker/port-check.txt
check "metal-worker err log"       bundle_has metal-worker/logs/metal-worker.err.log
check "env.txt"                    bundle_has env.txt
check "license.txt"                bundle_has license.txt
check "README.txt"                 bundle_has README.txt
check "collect.log present"        test -e "$BUNDLE/collect.log"

printf '\n-- must survive redaction\n'
check "worker host setting kept"   in_bundle 'MEMVEC_QUERY_WORKER_HOST=host.docker.internal'
check "hive uuid kept"             in_bundle '0d7aece3-77de-4412-8ce2-06a8c460ca88'
check "health version kept"        in_file container/health.json '"version":"1.7.0"'
check "worker version kept"        in_file metal-worker/version.txt 'v1.7.0'

printf '\n-- presence only, never the files\n'
check "license.txt says present"   in_file license.txt 'license-key: present'
check "machine-id hashed only"     in_file license.txt 'sha256 prefix'
# shellcheck disable=SC2016  # bash -c takes its args positionally as "$1";
# the single quotes are the point
check "raw fingerprint absent"     bash -c '! grep -rqF -- "fingerprint-uuid-1234" "$1"' _ "$BUNDLE"
# shellcheck disable=SC2016  # bash -c takes its args positionally as "$1";
# the single quotes are the point
check "no license-key file copied" bash -c '! find "$1" -name license-key | grep -q .' _ "$BUNDLE"
# shellcheck disable=SC2016  # bash -c takes its args positionally as "$1";
# the single quotes are the point
check "no database copied"         bash -c '! find "$1" -name "*.db" | grep -q .' _ "$BUNDLE"
# shellcheck disable=SC2016  # bash -c takes its args positionally as "$1";
# the single quotes are the point
check "no lance data copied"       bash -c '! find "$1" -name "*.lance" | grep -q .' _ "$BUNDLE"

printf '\n-- output points at the archive\n'
check "prints archive path"        grep -qF -- "$(basename "$ARCHIVE")" "$WORK/run.log"
check "prints support address"     grep -q 'hello@neohive.ai' "$WORK/run.log"

printf '\n-- piped into bash, the shape curl | bash produces\n'
# The build above hands bash a path, so BASH_SOURCE[0] names a real file and a
# read of it passes. Piping leaves it unset, which under `set -u` aborts before
# anything prints, and `usage` is where the path is read. `cat` rather than a
# redirect on purpose: the redirect gives bash a seekable file, and only the
# pipe reproduces what curl hands it.
# shellcheck disable=SC2002  # the cat is the point: only it makes stdin a pipe
run_piped() { cat "$SCRIPT" | PATH="$SHIM:$PATH" bash -s -- "$@"; }
set +e; PIPED="$(run_piped --help 2>&1)"; rc=$?; set -e
check "exit 0"                     test "$rc" -eq 0
check "usage still prints"         grep -q "Usage: logs.sh" <<<"$PIPED"

printf '\n%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ]
