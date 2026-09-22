#!/usr/bin/env bash
# NeoHive diagnostics bundle.
#
# Collects what NeoHive support needs to look into a problem and writes it
# to one file, neohive-diag-<stamp>.tar.gz, ready to attach to an email:
#
#   - the container's recent logs, its configuration (docker inspect),
#     the running image, /health, and how much of the data volume is used;
#   - on Apple Silicon, the Metal embedding worker's logs, its launchd
#     state, the rendered launch-agent plists and the installed version;
#   - the machine: OS, architecture, Docker version, free disk;
#   - which NEOHIVE_* / MEMVEC_* settings are in effect.
#
# What it never contains: your memories, indexed code or documents, the
# databases, or credentials. Every text file passes through one redaction
# filter that blanks the value of anything named like a key, secret,
# token, password or licence, plus bearer tokens and long opaque strings.
# The cached licence key itself is looked for but only its presence is
# recorded, and the licence-seat fingerprint is reduced to a hash. Look
# inside the archive before sending if you want to check:
#   tar -tzf neohive-diag-*.tar.gz
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/logs.sh | bash
#   ./logs.sh [--out <dir>] [--tail <lines>] [--since <duration>]
#
# Flags:
#   --out <dir>        where to write the archive (default: current directory)
#   --tail <lines>     how many recent container log lines to include (default 2000)
#   --since <dur>      only container logs newer than this, e.g. 24h or 2026-09-14T09:00
#
# Env (same knobs the installer honours):
#   XDG_CACHE_HOME             cache root (default ~/.cache)
#   NEOHIVE_CONTAINER_NAME     container to inspect (default neohive)
#   NEOHIVE_VOLUME_NAME        data volume (default neohive-data)
#   NEOHIVE_PORT               published port, for /health (default 3577)
#   NEOHIVE_METAL_WORKER_PORT  worker gRPC port, for the reachability check (default 50051)

set -euo pipefail

# This script's own path on disk, captured out here because the top level is
# the only place it is reliable: inside a function bash sets BASH_SOURCE[0]
# to the literal string "main", which would then be read as a filename.
# Empty means bash read this from a pipe (curl ... | bash) and there is no
# file at all. Under bash <(...) it is set but names a pipe rather than a
# regular file, so anything that opens it tests with -f, not -n.
SELF_PATH="${BASH_SOURCE[0]:-}"

CONTAINER_NAME="${NEOHIVE_CONTAINER_NAME:-neohive}"
VOLUME_NAME="${NEOHIVE_VOLUME_NAME:-neohive-data}"
PORT="${NEOHIVE_PORT:-3577}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/neohive"
LICENSE_CACHE_FILE="$CACHE_DIR/license-key"
FP_CACHE_FILE="$CACHE_DIR/machine-id"
NEOHIVE_HOME="$HOME/.neohive"
METAL_WORKER_ROOT="$NEOHIVE_HOME/metal-worker/current"
METAL_WORKER_LABEL="com.neohive.metal-worker"
WATCHDOG_LABEL="com.neohive.metal-worker-watchdog"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
METAL_WORKER_PORT="${NEOHIVE_METAL_WORKER_PORT:-50051}"
SUPPORT_EMAIL="hello@neohive.ai"

# -- Colour palette (mirrors install.sh) -------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_VIOLET=$'\033[38;5;99m'
  C_CYAN=$'\033[38;5;81m'
  C_GREEN=$'\033[38;5;78m'
  C_RED=$'\033[38;5;203m'
  C_YELLOW=$'\033[38;5;221m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_VIOLET='' C_CYAN='' C_GREEN='' C_RED='' C_YELLOW=''
fi

# -- Logging helpers (mirror install.sh; same Exxx code scheme) --------
step() { printf '%s[%s]%s %s\n' "$C_CYAN" "$1" "$C_RESET" "$2"; }
info() { printf '      %s\n' "$*"; }
ok() {
  if [ $# -gt 0 ] && [ -n "$1" ]; then
    printf '      %sOK%s  %s\n' "$C_GREEN" "$C_RESET" "$1"
  else
    printf '      %sOK%s\n' "$C_GREEN" "$C_RESET"
  fi
}
warn() { printf '      %sWARN%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() {
  local code="$1"; shift
  printf '      %sFAIL [%s]%s  %s\n' "$C_RED" "$code" "$C_RESET" "$*" >&2
  exit 1
}

# -- Redaction -----------------------------------------------------------
# One filter, applied to every text file in the bundle. Portable sed only
# (BSD sed has no case-insensitive flag), so the name classes spell out
# both cases. Three passes, in this order:
#   1. Authorization bearer tokens and GitHub tokens wherever they appear.
#      These run first: "authorization:" also matches the name pass below,
#      which would blank the word "Bearer" and leave the token standing.
#   2. name=value and "name": "value" where the name mentions key, secret,
#      token, passw(ord), licen(c|s)e, auth or credential - the value goes.
#      This is what catches NEOHIVE_LICENSE_KEY in docker inspect.
#   3. Any run of 40+ opaque characters (base64/hex-looking). Image digests
#      go too; that is a price worth paying for not guessing at formats.
# Then, when the cached licence key can be read, its literal value is
# replaced everywhere as a last line of defence against a log that printed
# it in a shape the patterns above do not know.
SECRET_NAME='[A-Za-z0-9_.-]*([Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww]|[Ll][Ii][Cc][Ee][Nn][CcSs][Ee]|[Aa][Uu][Tt][Hh]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll])[A-Za-z0-9_.-]*'
LICENSE_LITERAL=""

redact() {
  sed -E \
    -e 's/([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e "s/(\"?${SECRET_NAME}\"?[[:space:]]*[=:][[:space:]]*\"?)[^\"[:space:],;]+/\1[REDACTED]/g" \
    -e 's/[A-Za-z0-9+\/=_-]{40,}/[REDACTED]/g' \
  | if [ -n "$LICENSE_LITERAL" ]; then
      sed -e "s|$(printf '%s' "$LICENSE_LITERAL" | sed 's/[.[\*^$|]/\\&/g')|[REDACTED]|g"
    else
      cat
    fi
}

# -- Collection ------------------------------------------------------------
# Every collector is best-effort: a missing tool or a stopped container
# leaves a note in collect.log rather than stopping the run, because a
# bundle with gaps is still the thing support needs.
BUNDLE=""
COLLECT_LOG=""

capture() {
  # capture <file> <command...> - runs the command, redacts, records failures.
  local out="$BUNDLE/$1"; shift
  mkdir -p "$(dirname "$out")"
  if ! "$@" 2>&1 | redact > "$out"; then
    printf '%s: exit %s from: %s\n' "${out#"$BUNDLE"/}" "${PIPESTATUS[0]}" "$*" >> "$COLLECT_LOG"
  fi
  [ -s "$out" ] || printf '%s: empty\n' "${out#"$BUNDLE"/}" >> "$COLLECT_LOG"
}

capture_text() {
  # capture_text <file> <string> - writes literal text through the redactor.
  local out="$BUNDLE/$1"; shift
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$*" | redact > "$out"
}

collect_system() {
  step 1 "Machine and Docker..."
  {
    printf 'date:  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'uname: %s\n' "$(uname -a)"
    if [ "$(uname -s)" = "Darwin" ] && command -v sw_vers >/dev/null 2>&1; then sw_vers; fi
    [ -r /etc/os-release ] && cat /etc/os-release
    printf '\n--- disk ---\n'; df -h "$HOME" 2>/dev/null || df -h
    printf '\n--- docker ---\n'
    docker --version 2>&1 || printf 'docker: not found\n'
  } > "$BUNDLE/system.txt" 2>&1
  if docker info >/dev/null 2>&1; then
    capture docker-info.txt docker info
    capture docker-ps.txt docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    ok
  else
    printf 'docker info failed: Docker not running or not installed\n' >> "$COLLECT_LOG"
    warn "Docker is not running - container logs and config cannot be collected."
  fi
}

collect_container() {
  step 2 "Container '$CONTAINER_NAME'..."
  docker info >/dev/null 2>&1 || { info "skipped (Docker not running)"; return 0; }
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    printf 'container %s: not found\n' "$CONTAINER_NAME" >> "$COLLECT_LOG"
    info "no container named '$CONTAINER_NAME' on this machine"
    return 0
  fi
  local log_args=(--tail "$TAIL_LINES")
  [ -n "$SINCE" ] && log_args+=(--since "$SINCE")
  capture container/docker-logs.txt docker logs "${log_args[@]}" --timestamps "$CONTAINER_NAME"
  capture container/docker-inspect.json docker inspect "$CONTAINER_NAME"
  capture container/volume-inspect.json docker volume inspect "$VOLUME_NAME"
  capture container/image.txt docker inspect --format '{{.Config.Image}} {{.Image}}' "$CONTAINER_NAME"
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    # Sizes and layout only - names of hive directories are ids, never content.
    capture container/data-usage.txt docker exec "$CONTAINER_NAME" sh -c 'du -sh /app/data 2>/dev/null; echo; du -sh /app/data/* 2>/dev/null; echo; find /app/data -maxdepth 3 \( -name "*.db" -o -name "*.lance" \) -exec ls -ld {} + 2>/dev/null'
    capture container/processes.txt docker top "$CONTAINER_NAME"
    if command -v curl >/dev/null 2>&1; then
      capture container/health.json curl -fsS --max-time 10 "http://localhost:$PORT/health"
    else
      printf 'health: curl not installed on host\n' >> "$COLLECT_LOG"
    fi
  else
    printf 'container %s: not running - health and data usage skipped\n' "$CONTAINER_NAME" >> "$COLLECT_LOG"
  fi
  ok
}

collect_metal_worker() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  step 3 "Metal embedding worker..."
  if [ ! -d "$METAL_WORKER_ROOT" ] && [ ! -f "$LAUNCH_AGENTS/$METAL_WORKER_LABEL.plist" ]; then
    info "not installed"
    printf 'metal worker: not installed\n' >> "$COLLECT_LOG"
    return 0
  fi
  mkdir -p "$BUNDLE/metal-worker"
  capture metal-worker/version.txt cat "$METAL_WORKER_ROOT/VERSION"
  capture metal-worker/bin-listing.txt ls -la "$METAL_WORKER_ROOT/bin"
  capture metal-worker/launchctl-list.txt sh -c "launchctl list | grep -i neohive || echo 'no neohive agents loaded'"
  capture metal-worker/launchctl-print-worker.txt launchctl print "gui/$(id -u)/$METAL_WORKER_LABEL"
  capture metal-worker/launchctl-print-watchdog.txt launchctl print "gui/$(id -u)/$WATCHDOG_LABEL"
  local p
  for p in "$METAL_WORKER_LABEL" "$WATCHDOG_LABEL"; do
    [ -f "$LAUNCH_AGENTS/$p.plist" ] && capture "metal-worker/$p.plist" cat "$LAUNCH_AGENTS/$p.plist"
  done
  local f
  for f in "$NEOHIVE_HOME"/logs/*.log; do
    [ -f "$f" ] || continue
    capture "metal-worker/logs/$(basename "$f")" tail -n "$TAIL_LINES" "$f"
  done
  if command -v nc >/dev/null 2>&1; then
    if nc -z 127.0.0.1 "$METAL_WORKER_PORT" >/dev/null 2>&1; then
      capture_text metal-worker/port-check.txt "127.0.0.1:$METAL_WORKER_PORT reachable"
    else
      capture_text metal-worker/port-check.txt "127.0.0.1:$METAL_WORKER_PORT NOT reachable"
    fi
  fi
  ok
}

collect_env() {
  step 4 "Settings..."
  # Host-side knobs the installer reads. Values pass through redact, so a
  # NEOHIVE_LICENSE_KEY exported in the shell is blanked like any other.
  capture env.txt sh -c 'env | grep -E "^(NEOHIVE_|MEMVEC_|XDG_CACHE_HOME=|DOCKER_|TMPDIR=)" | LC_ALL=C sort || echo "(none set)"'
  {
    if [ -f "$LICENSE_CACHE_FILE" ]; then
      printf 'license-key: present (%s, mode %s)\n' "$LICENSE_CACHE_FILE" "$(stat -f '%Lp' "$LICENSE_CACHE_FILE" 2>/dev/null || stat -c '%a' "$LICENSE_CACHE_FILE" 2>/dev/null || echo '?')"
    else
      printf 'license-key: absent (%s)\n' "$LICENSE_CACHE_FILE"
    fi
    if [ -f "$FP_CACHE_FILE" ]; then
      local digest
      digest="$( (sha256sum "$FP_CACHE_FILE" 2>/dev/null || shasum -a 256 "$FP_CACHE_FILE" 2>/dev/null) | cut -c1-16)"
      printf 'machine-id:  present, sha256 prefix %s\n' "${digest:-unavailable}"
    else
      printf 'machine-id:  absent (%s)\n' "$FP_CACHE_FILE"
    fi
  } > "$BUNDLE/license.txt"
  ok
}

write_readme() {
  cat > "$BUNDLE/README.txt" <<EOF
NeoHive diagnostics bundle
created:   $(date -u +%Y-%m-%dT%H:%M:%SZ)
container: $CONTAINER_NAME
host:      $(uname -s)/$(uname -m)

Contents
  system.txt, docker-info.txt, docker-ps.txt   machine and Docker
  container/                                   logs, inspect, health, data sizes
  metal-worker/                                Apple Silicon worker (when installed)
  env.txt, license.txt                         settings; licence presence only
  collect.log                                  anything that could not be collected

Every text file was passed through a redaction filter: values of keys,
secrets, tokens, passwords and licence keys are replaced with [REDACTED].
No memories, indexed content or databases are included.

Send this file to $SUPPORT_EMAIL with a short description of the problem.
EOF
}

# ----------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------
# A piped script has no SELF_PATH and cannot be sourced, so -n keeps it out of
# a return that would be invalid at top level.
if [ -n "$SELF_PATH" ] && [ "$SELF_PATH" != "${0}" ] && [ "${NEOHIVE_LIB_ONLY:-0}" = "1" ]; then
  return 0
fi

usage() {
  # No readable file to lift the header comment from, so the flag list below
  # is all the help there is.
  if [ -f "$SELF_PATH" ]; then
    sed -n '2,/^$/p' "$SELF_PATH" | sed 's/^# \{0,1\}//'
  fi
  printf '\nUsage: logs.sh [--out <dir>] [--tail <lines>] [--since <duration>]\n'
}

OUT_DIR="$PWD"
TAIL_LINES=2000
SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out=*)    OUT_DIR="${1#*=}"; shift ;;
    --out)      [ $# -lt 2 ] && fail E205 "$1 requires a directory argument."; OUT_DIR="$2"; shift 2 ;;
    --tail=*)   TAIL_LINES="${1#*=}"; shift ;;
    --tail)     [ $# -lt 2 ] && fail E205 "$1 requires a number."; TAIL_LINES="$2"; shift 2 ;;
    --since=*)  SINCE="${1#*=}"; shift ;;
    --since)    [ $# -lt 2 ] && fail E205 "$1 requires a duration or timestamp."; SINCE="$2"; shift 2 ;;
    --help|-h)  usage; exit 0 ;;
    --) shift; break ;;
    -*) fail E206 "Unknown argument: $1" ;;
    *) shift ;;
  esac
done
printf '%s' "$TAIL_LINES" | grep -qE '^[1-9][0-9]*$' || fail E211 "--tail must be a positive integer (got '$TAIL_LINES')."
[ -d "$OUT_DIR" ] || fail E209 "--out directory does not exist: $OUT_DIR"

printf '\n    %s%sNeoHive diagnostics%s\n\n' "$C_BOLD" "$C_VIOLET" "$C_RESET"

STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="neohive-diag-$STAMP"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/neohive-diag.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BUNDLE="$WORK/$NAME"
COLLECT_LOG="$BUNDLE/collect.log"
mkdir -p "$BUNDLE"
: > "$COLLECT_LOG"

# Read the cached key once so its literal value can be scrubbed from every
# file. The file itself is never copied.
if [ -r "$LICENSE_CACHE_FILE" ]; then
  LICENSE_LITERAL="$(tr -d '[:space:]' < "$LICENSE_CACHE_FILE" 2>/dev/null || true)"
  [ "${#LICENSE_LITERAL}" -ge 8 ] || LICENSE_LITERAL=""
fi

collect_system
collect_container
collect_metal_worker
collect_env
write_readme

ARCHIVE="$(cd "$OUT_DIR" && pwd)/$NAME.tar.gz"
COPYFILE_DISABLE=1 tar -C "$WORK" -czf "$ARCHIVE" "$NAME" || fail E610 "Could not write $ARCHIVE"

LINE=$(printf '%*s' 67 '' | tr ' ' '-')
printf '\n   %s%s%s\n' "$C_DIM" "$LINE" "$C_RESET"
printf '   %s%sDiagnostics collected.%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
printf '     %s%s%s  (%s)\n\n' "$C_CYAN" "$ARCHIVE" "$C_RESET" "$(du -sh "$ARCHIVE" | cut -f1)"
if [ -s "$COLLECT_LOG" ]; then
  printf '   Some items could not be collected - see collect.log inside the archive.\n'
fi
printf '   Secrets were redacted and no memory content is included. To check:\n'
printf '     %star -tzf %s%s\n\n' "$C_CYAN" "$ARCHIVE" "$C_RESET"
printf '   Send it to %s%s%s with a short description of the problem.\n' "$C_CYAN" "$SUPPORT_EMAIL" "$C_RESET"
printf '   %s%s%s\n\n' "$C_DIM" "$LINE" "$C_RESET"
