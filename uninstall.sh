#!/usr/bin/env bash
# NeoHive uninstaller.
#
# Removes everything the installer put on this machine, in the reverse
# order it was put there:
#
#   1. The Apple Silicon Metal embedding worker and its watchdog (macOS
#      only, and only when they are installed). Both launchd agents are
#      booted out before their files go - a plain kill is not enough,
#      KeepAlive and the watchdog would bring the worker straight back.
#   2. The neohive container. It is stopped before it is removed so the
#      gateway releases its licence seat instead of dying with it held.
#   3. The cached licence key under ~/.cache/neohive.
#
# What it keeps unless --purge-data is given, because both are needed to
# reinstall without surprises:
#
#   - The neohive-data volume: every hive, memory and index. Removing it
#     is irreversible, so it sits behind its own typed confirmation and
#     the script offers to run backup.sh first.
#   - ~/.cache/neohive/machine-id: the licence-seat fingerprint. Deleting
#     it does not free the seat - the seat is released server-side when
#     the container stops - it only makes the next install take a new one.
#
# Removing the agent plugin and MCP entries happens inside each editor,
# so those steps are printed at the end rather than attempted here.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/uninstall.sh | bash
#   ./uninstall.sh [--purge-data] [--yes] [--dry-run]
#
# Flags:
#   --purge-data  also remove the data volume, ~/.neohive (models, logs)
#                 and all of ~/.cache/neohive. Asks you to type the volume
#                 name unless --yes is given.
#   --yes, -y     skip every confirmation. For scripted use only.
#   --dry-run     print the plan and exit without changing anything.
#
# Env (same knobs the installer honours):
#   XDG_CACHE_HOME             cache root (default ~/.cache)
#   NEOHIVE_CONTAINER_NAME     container to remove (default neohive)
#   NEOHIVE_VOLUME_NAME        data volume (default neohive-data)
#   NEOHIVE_METAL_WORKER_PORT  worker port, shown in the plan (default 50051)

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
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/neohive"
LICENSE_CACHE_FILE="$CACHE_DIR/license-key"
FP_CACHE_FILE="$CACHE_DIR/machine-id"

NEOHIVE_HOME="$HOME/.neohive"
METAL_WORKER_ROOT="$NEOHIVE_HOME/metal-worker"
METAL_WORKER_LABEL="com.neohive.metal-worker"
WATCHDOG_LABEL="com.neohive.metal-worker-watchdog"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
METAL_WORKER_PORT="${NEOHIVE_METAL_WORKER_PORT:-50051}"

BACKUP_URL="https://raw.githubusercontent.com/NeoHiveAI/install/main/backup.sh"

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
  # A dry run reaches these call sites too, and the messages are past tense
  # ("container removed"). The run helper has already printed a "would run"
  # line for every command, so say nothing rather than sign off work that was
  # deliberately skipped.
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
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

# -- Prompting ----------------------------------------------------------
# The supported invocation is `curl ... | bash`, which makes stdin the
# script itself, so a bare `read` would eat the next lines of this file.
# Answers are read from the terminal device instead (opened once, on the
# first question), and the questions go to stderr, which is the terminal
# under a pipe too. Without a terminal and without --yes there is no safe
# answer, so the script stops instead of guessing. NEOHIVE_TTY points the
# reads somewhere else; the tests use it to feed canned answers.
ASSUME_YES=0
DRY_RUN=0
PURGE_DATA=0
TTY_DEV="${NEOHIVE_TTY:-/dev/tty}"
TTY_OPEN=0
ASK_ANSWER=""

ask() {
  # ask "<prompt>" -> sets ASK_ANSWER. A variable rather than stdout so the
  # call runs in this shell: inside $(...) a fail here would only end the
  # subshell, and the opened terminal fd would not carry to the next question.
  ASK_ANSWER=""
  if [ "$ASSUME_YES" = "1" ]; then ASK_ANSWER="yes"; return 0; fi
  if [ "$TTY_OPEN" = "0" ]; then
    # Probe in a subshell first: a failed exec redirection would otherwise
    # take the whole script down without the error below.
    if ! ( exec 3<"$TTY_DEV" ) 2>/dev/null; then
      fail E207 "No terminal to confirm on. Re-run interactively, or pass --yes to skip confirmations."
    fi
    exec 3<"$TTY_DEV"
    TTY_OPEN=1
  fi
  printf '%s' "$1" >&2
  IFS= read -r -u 3 ASK_ANSWER || ASK_ANSWER=""
}

confirm_yes_no() {
  # confirm_yes_no "<question>" -> 0 for y/yes, 1 otherwise. Default is no.
  ask "$1 [y/N] "
  case "$ASK_ANSWER" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# -- Detection ------------------------------------------------------------
# Every check reads the machine, not the installer's defaults: the plan
# only lists what is actually there, and a clean machine ends with
# "nothing to remove" rather than a list of failed deletes.
HAVE_DOCKER=0
HAVE_CONTAINER=0
CONTAINER_RUNNING=0
HAVE_VOLUME=0
HAVE_LICENSE=0
HAVE_FINGERPRINT=0
HAVE_WORKER_FILES=0
HAVE_WORKER_AGENT=0
HAVE_WATCHDOG_AGENT=0
HAVE_WORKER_PLIST=0
HAVE_WATCHDOG_PLIST=0
HAVE_NEOHIVE_HOME=0
IS_MAC=0
[ "$(uname -s)" = "Darwin" ] && IS_MAC=1

launch_agent_loaded() {
  # launchctl list prints one line per loaded job; the label is the third column.
  launchctl list 2>/dev/null | awk -v l="$1" '$3 == l { found = 1 } END { exit !found }'
}

detect() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    HAVE_DOCKER=1
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      HAVE_CONTAINER=1
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        CONTAINER_RUNNING=1
      fi
    fi
    if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
      HAVE_VOLUME=1
    fi
  fi
  [ -f "$LICENSE_CACHE_FILE" ] && HAVE_LICENSE=1
  [ -f "$FP_CACHE_FILE" ] && HAVE_FINGERPRINT=1
  [ -d "$NEOHIVE_HOME" ] && HAVE_NEOHIVE_HOME=1
  [ -d "$METAL_WORKER_ROOT" ] && HAVE_WORKER_FILES=1
  if [ "$IS_MAC" = "1" ]; then
    [ -f "$LAUNCH_AGENTS/$METAL_WORKER_LABEL.plist" ] && HAVE_WORKER_PLIST=1
    [ -f "$LAUNCH_AGENTS/$WATCHDOG_LABEL.plist" ] && HAVE_WATCHDOG_PLIST=1
    launch_agent_loaded "$METAL_WORKER_LABEL" && HAVE_WORKER_AGENT=1
    launch_agent_loaded "$WATCHDOG_LABEL" && HAVE_WATCHDOG_AGENT=1
  fi
  return 0
}

have_worker() {
  [ "$HAVE_WORKER_FILES" = "1" ] || [ "$HAVE_WORKER_AGENT" = "1" ] || [ "$HAVE_WATCHDOG_AGENT" = "1" ] \
    || [ "$HAVE_WORKER_PLIST" = "1" ] || [ "$HAVE_WATCHDOG_PLIST" = "1" ]
}

anything_to_remove() {
  [ "$HAVE_CONTAINER" = "1" ] || [ "$HAVE_LICENSE" = "1" ] || have_worker \
    || { [ "$PURGE_DATA" = "1" ] && { [ "$HAVE_VOLUME" = "1" ] || [ "$HAVE_FINGERPRINT" = "1" ] || [ "$HAVE_NEOHIVE_HOME" = "1" ]; }; }
}

# -- Plan -----------------------------------------------------------------
print_plan() {
  printf '\n   %sThis will remove:%s\n' "$C_BOLD" "$C_RESET"
  if have_worker; then
    local state="not loaded"
    [ "$HAVE_WORKER_AGENT" = "1" ] && state="loaded, port $METAL_WORKER_PORT"
    info "- Metal embedding worker ($METAL_WORKER_LABEL, $state)"
    info "  and its watchdog ($WATCHDOG_LABEL)"
    [ "$HAVE_WORKER_FILES" = "1" ] && info "  files: $METAL_WORKER_ROOT"
  fi
  if [ "$HAVE_CONTAINER" = "1" ]; then
    local state="stopped"
    [ "$CONTAINER_RUNNING" = "1" ] && state="running"
    info "- Container '$CONTAINER_NAME' ($state)"
  fi
  [ "$HAVE_LICENSE" = "1" ] && info "- Cached licence key: $LICENSE_CACHE_FILE"

  if [ "$PURGE_DATA" = "1" ]; then
    printf '\n   %s%sAnd permanently delete:%s\n' "$C_BOLD" "$C_RED" "$C_RESET"
    [ "$HAVE_VOLUME" = "1" ] && info "- Data volume '$VOLUME_NAME' (all hives, memories and indexes)"
    [ "$HAVE_FINGERPRINT" = "1" ] && info "- Licence-seat fingerprint: $FP_CACHE_FILE"
    [ "$HAVE_NEOHIVE_HOME" = "1" ] && info "- $NEOHIVE_HOME (worker models and logs)"
  else
    printf '\n   %sKept (pass --purge-data to remove):%s\n' "$C_BOLD" "$C_RESET"
    [ "$HAVE_VOLUME" = "1" ] && info "- Data volume '$VOLUME_NAME' - your hives and memories"
    [ "$HAVE_FINGERPRINT" = "1" ] && info "- $FP_CACHE_FILE - licence-seat fingerprint, reused on reinstall"
    [ "$HAVE_NEOHIVE_HOME" = "1" ] && [ "$HAVE_WORKER_FILES" = "0" ] && info "- $NEOHIVE_HOME (worker models and logs)"
    [ "$HAVE_NEOHIVE_HOME" = "1" ] && [ "$HAVE_WORKER_FILES" = "1" ] && info "- $NEOHIVE_HOME/models and logs"
  fi
  printf '\n'
}

# -- Actions --------------------------------------------------------------
# Each action is a no-op in --dry-run and tolerant of a half-removed
# machine: a re-run after a partial failure finishes the job instead of
# stopping on the first thing that is already gone.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    info "${C_DIM}would run: $*${C_RESET}"
    return 0
  fi
  "$@"
}

remove_metal_worker() {
  have_worker || return 0
  step 1 "Stopping the Metal embedding worker..."
  # Watchdog first: it exists to restart the worker, so it must be gone
  # before the worker is. bootout of an unloaded label is a harmless no-op.
  run launchctl bootout "gui/$(id -u)/$WATCHDOG_LABEL" 2>/dev/null || true
  run launchctl bootout "gui/$(id -u)/$METAL_WORKER_LABEL" 2>/dev/null || true
  run rm -f "$LAUNCH_AGENTS/$WATCHDOG_LABEL.plist" "$LAUNCH_AGENTS/$METAL_WORKER_LABEL.plist"
  run rm -rf "$METAL_WORKER_ROOT"
  ok "Metal worker and watchdog removed"
}

remove_container() {
  [ "$HAVE_CONTAINER" = "1" ] || return 0
  step 2 "Removing container '$CONTAINER_NAME'..."
  if [ "$CONTAINER_RUNNING" = "1" ]; then
    # A graceful stop lets the gateway release its licence seat.
    run docker stop --time 30 "$CONTAINER_NAME" >/dev/null 2>&1 || warn "Container did not stop cleanly; removing anyway."
  fi
  run docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  ok "container removed"
}

remove_license_cache() {
  [ "$HAVE_LICENSE" = "1" ] || return 0
  step 3 "Removing cached licence key..."
  run rm -f "$LICENSE_CACHE_FILE"
  ok
}

purge_data() {
  [ "$PURGE_DATA" = "1" ] || return 0
  step 4 "Deleting data..."
  if [ "$HAVE_VOLUME" = "1" ]; then
    run docker volume rm "$VOLUME_NAME" >/dev/null || fail E604 "Could not remove volume '$VOLUME_NAME'. Is a container still using it? (docker ps -a --filter volume=$VOLUME_NAME)"
    ok "volume '$VOLUME_NAME' deleted"
  fi
  if [ "$HAVE_FINGERPRINT" = "1" ] || [ -d "$CACHE_DIR" ]; then
    run rm -rf "$CACHE_DIR"
    ok "$CACHE_DIR deleted"
  fi
  if [ "$HAVE_NEOHIVE_HOME" = "1" ]; then
    run rm -rf "$NEOHIVE_HOME"
    ok "$NEOHIVE_HOME deleted"
  fi
}

print_manual_steps() {
  local line data_verb
  line=$(printf '%*s' 67 '' | tr ' ' '-')
  printf '\n   %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
  # This block is the last thing on screen, so a dry run must not sign off as
  # though it had removed anything. The editor steps below are advice either way.
  if [ "$DRY_RUN" = "1" ]; then
    printf '   %s%sDry run finished. Nothing on this machine was changed.%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
    printf '   %sAfter a real run, finish in your editor%s - these live in its own config, not here:\n\n' "$C_BOLD" "$C_RESET"
  else
    printf '   %s%sNeoHive has been removed from this machine.%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf '   %sFinish in your editor%s - these live in its own config, not here:\n\n' "$C_BOLD" "$C_RESET"
  fi
  printf '     Claude Code plugin:   %s/plugin uninstall neohive@neohive-claude%s\n' "$C_CYAN" "$C_RESET"
  printf '     Claude Code MCP:      %sclaude mcp list%s   then   %sclaude mcp remove <neohive-entry>%s\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  printf '     Cursor / Codex:       remove the NeoHive entries from the MCP config (e.g. .mcp.json)\n'
  if [ "$PURGE_DATA" = "0" ] && [ "$HAVE_VOLUME" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then data_verb='would stay in'; else data_verb='is still in'; fi
    printf '\n   Your data %s the %s%s%s volume. Reinstalling picks it up again;\n' "$data_verb" "$C_CYAN" "$VOLUME_NAME" "$C_RESET"
    printf '   to delete it later:  %sdocker volume rm %s%s\n' "$C_CYAN" "$VOLUME_NAME" "$C_RESET"
  fi
  printf '   %s%s%s\n\n' "$C_DIM" "$line" "$C_RESET"
}

# ----------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------
# Library mode for tests: sourced with NEOHIVE_LIB_ONLY=1 loads only the
# functions above. Guarded on SELF_PATH vs $0 so direct execution never
# returns early. A piped script has no SELF_PATH and cannot be sourced,
# so -n keeps it out of a return that would be invalid at top level.
if [ -n "$SELF_PATH" ] && [ "$SELF_PATH" != "${0}" ] && [ "${NEOHIVE_LIB_ONLY:-0}" = "1" ]; then
  return 0
fi

usage() {
  # No readable file to lift the header comment from, so the flag list below
  # is all the help there is.
  if [ -f "$SELF_PATH" ]; then
    sed -n '2,/^$/p' "$SELF_PATH" | sed 's/^# \{0,1\}//'
  fi
  printf '\nUsage: uninstall.sh [--purge-data] [--yes] [--dry-run]\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge-data) PURGE_DATA=1; shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --help|-h)    usage; exit 0 ;;
    --) shift; break ;;
    -*) fail E206 "Unknown argument: $1" ;;
    *) shift ;;
  esac
done

printf '\n    %s%sNeoHive uninstaller%s\n\n' "$C_BOLD" "$C_VIOLET" "$C_RESET"

detect
if [ "$HAVE_DOCKER" = "0" ]; then
  warn "Docker is not running or not installed - the container and volume cannot be checked or removed. Start Docker and re-run to clean those up."
fi

if ! anything_to_remove; then
  info "Nothing to remove: no NeoHive container, licence cache or Metal worker found on this machine."
  [ "$HAVE_VOLUME" = "1" ] && [ "$PURGE_DATA" = "0" ] && info "The data volume '$VOLUME_NAME' is present. Pass --purge-data to delete it."
  exit 0
fi

print_plan
[ "$DRY_RUN" = "1" ] && info "${C_DIM}--dry-run: nothing will be changed${C_RESET}"

if ! confirm_yes_no "   Continue?"; then
  info "Aborted. Nothing was changed."
  exit 0
fi

# The volume is the one irreversible item, so it gets its own gate even
# after the general yes - and a way out via a backup first.
if [ "$PURGE_DATA" = "1" ] && [ "$HAVE_VOLUME" = "1" ] && [ "$ASSUME_YES" = "0" ]; then
  printf '\n'
  if [ "$CONTAINER_RUNNING" = "1" ] && confirm_yes_no "   Back up your data first? (runs backup.sh, writes a .tar.gz here)"; then
    if [ "$DRY_RUN" = "1" ]; then
      info "${C_DIM}would run: backup.sh${C_RESET}"
    elif [ -f "$SELF_PATH" ] && [ -x "$(dirname "$SELF_PATH")/backup.sh" ]; then
      NEOHIVE_CONTAINER_NAME="$CONTAINER_NAME" bash "$(dirname "$SELF_PATH")/backup.sh" || fail E605 "Backup failed - data left untouched."
    else
      curl -fsSL "$BACKUP_URL" | NEOHIVE_CONTAINER_NAME="$CONTAINER_NAME" bash || fail E605 "Backup failed - data left untouched."
    fi
  fi
  printf '\n   %s%sDeleting the volume cannot be undone.%s\n' "$C_BOLD" "$C_RED" "$C_RESET"
  ask "   Type the volume name ($VOLUME_NAME) to confirm: "
  if [ "$ASK_ANSWER" != "$VOLUME_NAME" ]; then
    warn "Volume name did not match. Continuing WITHOUT deleting the data volume."
    PURGE_DATA=0
  fi
fi

printf '\n'
remove_metal_worker
remove_container
remove_license_cache
purge_data
print_manual_steps
