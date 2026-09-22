#!/usr/bin/env bash
# NeoHive backup and restore.
#
# Writes a single portable archive, neohive-backup-<stamp>.tar.gz, holding
# everything in the data volume:
#
#   - every SQLite database (gateway.db, the registries, and each hive's
#     cognitive-memory.db), snapshotted with sqlite3's .backup so the copy
#     is consistent even while the server is writing;
#   - every vector index (the .lance directories) and the .encryption_key
#     files that credentials are encrypted with, copied as they are. A
#     vector index written during the copy comes out consistent but
#     possibly a moment stale, never corrupt: Lance commits its manifest
#     last.
#
# The archive carries a manifest.json (what was backed up, from which
# version) and SHA256SUMS, which --restore verifies before touching
# anything. The archive contains your memories and indexed content: keep
# it where you keep other private data.
#
# Restore stops the server, replaces the volume's contents with the
# archive's, and starts the server again. It reuses the image the
# container already runs, so it needs no download and no repo.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/backup.sh | bash
#   ./backup.sh [--out <dir>]
#   ./backup.sh --restore <neohive-backup-*.tar.gz> [--yes]
#
# Flags:
#   --out <dir>       where to write the archive (default: current directory)
#   --restore <file>  restore this archive into the running install
#   --yes, -y         skip the restore confirmation. For scripted use only.
#
# Env (same knobs the installer honours):
#   NEOHIVE_CONTAINER_NAME   container to back up (default neohive)
#   NEOHIVE_VOLUME_NAME      data volume (default neohive-data)
#   NEOHIVE_PORT             published port, used to wait for /health (default 3577)

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
DATA_DIR=/app/data
# How long a restore waits for /health after starting the container.
# Overridable so the tests do not sit through the full wait.
HEALTH_TIMEOUT_SECONDS="${NEOHIVE_HEALTH_TIMEOUT:-90}"
FORMAT_VERSION=1

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

ASSUME_YES=0
TTY_DEV="${NEOHIVE_TTY:-/dev/tty}"
TTY_OPEN=0
ASK_ANSWER=""

# Answers come from the terminal device, not stdin: under `curl | bash`
# stdin is this script, and a bare `read` would consume the lines that
# follow. Questions go to stderr. NEOHIVE_TTY redirects the reads; the
# tests use it to feed canned answers. The answer lands in ASK_ANSWER so
# the call runs in this shell - a fail inside $(...) would only end the
# subshell.
ask() {
  ASK_ANSWER=""
  if [ "$ASSUME_YES" = "1" ]; then ASK_ANSWER="yes"; return 0; fi
  if [ "$TTY_OPEN" = "0" ]; then
    if ! ( exec 3<"$TTY_DEV" ) 2>/dev/null; then
      fail E207 "No terminal to confirm on. Re-run interactively, or pass --yes to skip confirmations."
    fi
    exec 3<"$TTY_DEV"
    TTY_OPEN=1
  fi
  printf '%s' "$1" >&2
  IFS= read -r -u 3 ASK_ANSWER || ASK_ANSWER=""
}

# -- Portability -------------------------------------------------------
# macOS ships shasum, most Linux ships sha256sum; either produces the
# same "<hex>  <path>" lines, so SHA256SUMS verifies with both.
sha256_tool() {
  if command -v sha256sum >/dev/null 2>&1; then printf 'sha256sum'
  elif command -v shasum >/dev/null 2>&1; then printf 'shasum -a 256'
  else fail E208 "Neither sha256sum nor shasum is installed - cannot checksum the backup."
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || fail E201 "docker is not installed or not on PATH."
  docker info >/dev/null 2>&1 || fail E202 "Docker is not running. Start Docker Desktop (or the docker service) and retry."
}

container_exists() { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }
container_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }

container_image() { docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true; }

server_version() {
  # /health carries the running version; empty when the server is down or
  # curl is missing, and the manifest just records "unknown".
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS --max-time 5 "http://localhost:$PORT/health" 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1 || true
}

wait_for_health() {
  command -v curl >/dev/null 2>&1 || { info "curl not found - skipping the /health wait"; return 0; }
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS --max-time 3 "http://localhost:$PORT/health" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# -- Backup --------------------------------------------------------------
# The snapshot is assembled inside the container, where sqlite3 and the
# live files are, then copied out in one go. Everything under /app/data is
# taken except:
#   *.db and their -wal/-shm/-journal sidecars - replaced by the .backup
#     copies, which fold the WAL in and need no sidecar;
#   machine-id - the licence fingerprint the installer bind-mounts from
#     ~/.cache/neohive, not data, and read-only in the container anyway.
# shellcheck disable=SC2016  # runs inside the container's sh; $SNAP and $1 expand there
SNAPSHOT_SCRIPT='
set -eu
SNAP=/tmp/neohive-snapshot
rm -rf "$SNAP"; mkdir -p "$SNAP"
cd "$1"
find . -type f -name "*.db" | while IFS= read -r db; do
  mkdir -p "$SNAP/$(dirname "$db")"
  sqlite3 "$db" ".backup '"'"'$SNAP/$db'"'"'"
done
tar -cf - --exclude="*.db" --exclude="*.db-wal" --exclude="*.db-shm" --exclude="*.db-journal" --exclude="./machine-id" . \
  | tar -C "$SNAP" -xf -
'

do_backup() {
  local out_dir="$1"
  require_docker
  container_exists || fail E606 "No container named '$CONTAINER_NAME'. Is NeoHive installed on this machine?"
  container_running || fail E607 "Container '$CONTAINER_NAME' is not running. Start it first (docker start $CONTAINER_NAME) so the databases can be snapshotted consistently."
  [ -d "$out_dir" ] || fail E209 "--out directory does not exist: $out_dir"

  local stamp name work image version sha snapshot_files
  stamp="$(date +%Y%m%d-%H%M%S)"
  name="neohive-backup-$stamp"
  work="$(mktemp -d "${TMPDIR:-/tmp}/neohive-backup.XXXXXX")"
  # Expanded now, not when the trap fires: by then this function has
  # returned and its locals are gone, which under set -u would turn the
  # cleanup into an "unbound variable" exit 1 after a successful run.
  # shellcheck disable=SC2064  # expanding now is the point, see above
  trap "rm -rf '$work'; docker exec '$CONTAINER_NAME' rm -rf /tmp/neohive-snapshot >/dev/null 2>&1 || true" EXIT
  mkdir -p "$work/$name/data"
  sha="$(sha256_tool)"

  step 1 "Snapshotting databases inside the container..."
  docker exec "$CONTAINER_NAME" sh -c "$SNAPSHOT_SCRIPT" snapshot "$DATA_DIR" \
    || fail E608 "Snapshot failed inside the container. Run 'docker logs $CONTAINER_NAME' for details."
  ok

  step 2 "Copying the snapshot out..."
  docker cp "$CONTAINER_NAME:/tmp/neohive-snapshot/." "$work/$name/data/" >/dev/null \
    || fail E609 "Could not copy the snapshot out of the container."
  docker exec "$CONTAINER_NAME" rm -rf /tmp/neohive-snapshot >/dev/null 2>&1 || true
  # An empty snapshot is a failure, not a small backup: a fresh install still
  # has gateway.db, so nothing here means the copy did not happen. The count is
  # kept because it is the number the checksum list and the restore are both
  # measured against.
  snapshot_files="$(find "$work/$name/data" -type f | wc -l | tr -d ' ')"
  [ "$snapshot_files" -gt 0 ] \
    || fail E619 "The snapshot came out empty - no databases were copied. Check 'docker exec $CONTAINER_NAME ls $DATA_DIR' and retry."
  ok "$(du -sh "$work/$name/data" | cut -f1)"

  step 3 "Writing manifest and checksums..."
  image="$(container_image)"
  version="$(server_version)"
  # Sorted by path so the list reads in tree order, then re-emitted
  # NUL-separated: xargs splits a newline-delimited list on the spaces and tabs
  # inside a path as well, and hands the checksum tool two half-paths. printf
  # does the separating rather than `tr` because it is a bash builtin and
  # behaves the same on macOS's bash 3.2. A newline inside a filename does not
  # survive the sort and is not supported.
  # shellcheck disable=SC2086  # $sha is "shasum -a 256" on macOS: the split is the point
  ( cd "$work/$name" && find data -type f | LC_ALL=C sort \
      | while IFS= read -r f; do printf '%s\0' "$f"; done | xargs -0 $sha ) > "$work/$name/SHA256SUMS" \
    || fail E620 "Could not checksum the snapshot. Nothing was written."
  # Every file has to appear in the list, because verification only checks the
  # lines it is given.
  [ "$(wc -l < "$work/$name/SHA256SUMS" | tr -d ' ')" = "$snapshot_files" ] \
    || fail E621 "The checksum list does not cover all $snapshot_files files in the snapshot. Nothing was written."
  cat > "$work/$name/manifest.json" <<EOF
{
  "format": $FORMAT_VERSION,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "container": "$CONTAINER_NAME",
  "volume": "$VOLUME_NAME",
  "image": "${image:-unknown}",
  "neohive_version": "${version:-unknown}",
  "host": "$(uname -s)/$(uname -m)",
  "files": $snapshot_files
}
EOF
  ok

  step 4 "Compressing..."
  local archive
  archive="$(cd "$out_dir" && pwd)/$name.tar.gz"
  # COPYFILE_DISABLE stops macOS tar adding ._* metadata files.
  COPYFILE_DISABLE=1 tar -C "$work" -czf "$archive" "$name" || fail E610 "Could not write $archive"
  ok "$(du -sh "$archive" | cut -f1)"

  local line
  line=$(printf '%*s' 67 '' | tr ' ' '-')
  printf '\n   %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
  printf '   %s%sBackup complete.%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '     %s%s%s\n\n' "$C_CYAN" "$archive" "$C_RESET"
  printf '   It contains your memories and indexed content - store it like private data.\n'
  printf '   To restore:  %sbackup.sh --restore %s%s\n' "$C_CYAN" "$archive" "$C_RESET"
  printf '   %s%s%s\n\n' "$C_DIM" "$line" "$C_RESET"
}

# -- Restore -------------------------------------------------------------
# Runs in a throwaway container on the install's own image, so nothing is
# written from the host's uid or through a different libc. It counts the source
# before deleting anything, because only the container sees what the bind mount
# delivered: a host path the runtime does not share arrives as an empty
# directory, and cp -a from an empty directory succeeds. Exit 9 is that count
# refusing. cp -a keeps modes and times; nothing here is a symlink. The count,
# source and target are positional so the tests can run this same text against
# temporary directories instead of asserting on the command it appears in.
# shellcheck disable=SC2016  # runs inside the container's sh; the $n expand there
RESTORE_SCRIPT='
set -e
seen=$(find "$2" -type f | wc -l | tr -d " ")
[ "$seen" -ge "$1" ] || { echo "$2 holds $seen files, expected $1" >&2; exit 9; }
find "$3" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a "$2"/. "$3"/
'

do_restore() {
  local archive="$1"
  [ -f "$archive" ] || fail E210 "Archive not found: $archive"
  require_docker
  container_exists || fail E606 "No container named '$CONTAINER_NAME'. Install NeoHive first, then restore into it."
  local image
  image="$(container_image)"
  [ -n "$image" ] || fail E611 "Could not read the image from container '$CONTAINER_NAME'."

  local work top sha
  work="$(mktemp -d "${TMPDIR:-/tmp}/neohive-restore.XXXXXX")"
  # Expanded now: see the matching note in do_backup.
  # shellcheck disable=SC2064  # expanding now is the point, see above
  trap "rm -rf '$work'" EXIT
  sha="$(sha256_tool)"

  step 1 "Verifying $archive..."
  tar -C "$work" -xzf "$archive" || fail E612 "Could not extract the archive. Is it a neohive-backup-*.tar.gz?"
  top="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'neohive-backup-*' | head -1)"
  if [ -z "$top" ] || [ ! -f "$top/manifest.json" ] || [ ! -f "$top/SHA256SUMS" ] || [ ! -d "$top/data" ]; then
    fail E613 "Archive does not look like a NeoHive backup (missing manifest.json, SHA256SUMS or data/)."
  fi
  local fmt
  fmt="$(sed -n 's/.*"format": *\([0-9]*\).*/\1/p' "$top/manifest.json" | head -1)"
  [ "$fmt" = "$FORMAT_VERSION" ] || fail E614 "Backup format $fmt is not supported by this script (expects $FORMAT_VERSION)."
  # shellcheck disable=SC2086  # $sha is "shasum -a 256" on macOS: the split is the point
  ( cd "$top" && $sha -c SHA256SUMS --quiet ) || fail E615 "Checksum mismatch - the archive is damaged or was modified. Nothing was changed."
  ok "$(wc -l < "$top/SHA256SUMS" | tr -d ' ') files verified"
  # Verification proves every listed file is intact; it says nothing about a
  # file that was left out of the list. The manifest count is taken from the
  # snapshot tree, so comparing it against the extracted tree is what catches a
  # short archive - and it is the number the container guard below is given.
  local expected_files extracted_files
  expected_files="$(sed -n 's/.*"files": *\([0-9]*\).*/\1/p' "$top/manifest.json" | head -1)"
  extracted_files="$(find "$top/data" -type f | wc -l | tr -d ' ')"
  # A count of zero is rejected too. manifest.json is the one file SHA256SUMS
  # does not cover, so a damaged count reaches here unnoticed, and zero would
  # satisfy both this check and the container's.
  if [ -z "$expected_files" ] || [ "$expected_files" -lt 1 ] || [ "$extracted_files" -lt "$expected_files" ]; then
    fail E622 "The archive holds $extracted_files files and its manifest names ${expected_files:-none} - it is incomplete or its manifest is damaged. Nothing was changed."
  fi
  info "created:  $(sed -n 's/.*"created_at": *"\([^"]*\)".*/\1/p' "$top/manifest.json")"
  info "version:  $(sed -n 's/.*"neohive_version": *"\([^"]*\)".*/\1/p' "$top/manifest.json")"

  printf '\n   %s%sRestoring replaces everything in the "%s" volume with this backup.%s\n' "$C_BOLD" "$C_RED" "$VOLUME_NAME" "$C_RESET"
  printf '   The server is stopped for the copy and started again afterwards.\n'
  ask "   Type the volume name ($VOLUME_NAME) to continue: "
  if [ "$ASK_ANSWER" != "$VOLUME_NAME" ] && [ "$ASSUME_YES" = "0" ]; then
    info "Volume name did not match. Nothing was changed."
    exit 0
  fi
  printf '\n'

  local was_running=0
  if container_running; then
    was_running=1
    step 2 "Stopping $CONTAINER_NAME..."
    docker stop --time 60 "$CONTAINER_NAME" >/dev/null || fail E616 "Could not stop the container."
    ok
  else
    step 2 "Container is already stopped"
  fi

  step 3 "Replacing the volume contents..."
  # RESTORE_SCRIPT refuses with exit 9 when the mount came up short; any other
  # non-zero status is a copy failure. The server is already stopped by this
  # point, so E623 says the data is intact and how to start it again.
  local rc=0
  docker run --rm \
    -v "$VOLUME_NAME:/restore-target" \
    -v "$top/data:/restore-source:ro" \
    --entrypoint sh "$image" -c "$RESTORE_SCRIPT" \
    guard "$expected_files" /restore-source /restore-target >/dev/null || rc=$?
  [ "$rc" != "9" ] \
    || fail E623 "The container cannot see the backup files at /restore-source, so the volume was left untouched and the server is still stopped - 'docker start $CONTAINER_NAME' brings it back with your data as it was. The usual cause is the container runtime not sharing $work with its VM: Colima and Lima share only \$HOME and /tmp/colima by default. Re-run with TMPDIR set to a shared directory: mkdir -p \"\$HOME/.neohive-tmp\" && TMPDIR=\"\$HOME/.neohive-tmp\" backup.sh --restore $archive"
  [ "$rc" = "0" ] \
    || fail E617 "Copy into the volume failed after the old contents were deleted, so the volume is empty or half-written. Do not start the server on it - re-run the same restore. The server is still stopped."
  ok

  step 4 "Starting $CONTAINER_NAME..."
  docker start "$CONTAINER_NAME" >/dev/null || fail E618 "Could not start the container. Run 'docker logs $CONTAINER_NAME'."
  if wait_for_health; then
    ok "server healthy on port $PORT"
  else
    warn "Server did not report healthy within ${HEALTH_TIMEOUT_SECONDS}s. Check 'docker logs $CONTAINER_NAME'."
  fi
  [ "$was_running" = "1" ] || info "(the container was stopped before the restore; it is running now)"

  local line
  line=$(printf '%*s' 67 '' | tr ' ' '-')
  printf '\n   %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
  printf '   %s%sRestore complete.%s  Open %shttp://localhost:%s%s to check your hives.\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$C_CYAN" "$PORT" "$C_RESET"
  printf '   %s%s%s\n\n' "$C_DIM" "$line" "$C_RESET"
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
  printf '\nUsage: backup.sh [--out <dir>]\n       backup.sh --restore <file> [--yes]\n'
}

OUT_DIR="$PWD"
RESTORE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out=*)      OUT_DIR="${1#*=}"; shift ;;
    --out)        [ $# -lt 2 ] && fail E205 "$1 requires a directory argument."; OUT_DIR="$2"; shift 2 ;;
    --restore=*)  RESTORE_FILE="${1#*=}"; shift ;;
    --restore)    [ $# -lt 2 ] && fail E205 "$1 requires a file argument."; RESTORE_FILE="$2"; shift 2 ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    --help|-h)    usage; exit 0 ;;
    --) shift; break ;;
    -*) fail E206 "Unknown argument: $1" ;;
    *) shift ;;
  esac
done

if [ -n "$RESTORE_FILE" ]; then
  printf '\n    %s%sNeoHive restore%s\n\n' "$C_BOLD" "$C_VIOLET" "$C_RESET"
  do_restore "$RESTORE_FILE"
else
  printf '\n    %s%sNeoHive backup%s\n\n' "$C_BOLD" "$C_VIOLET" "$C_RESET"
  do_backup "$OUT_DIR"
fi
