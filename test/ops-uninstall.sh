#!/usr/bin/env bash
# Exercise uninstall.sh end to end without Docker or launchd. A temporary
# HOME carries a fake Metal worker install (files plus both plists), and a
# PATH shim replaces `docker`, `launchctl` and `uname` with fakes that answer
# like a Mac with a running install and append every call to a log. The
# assertions are on that log and on what is left in HOME:
#
#   1. --dry-run prints the full plan, changes nothing, and signs off as a
#      dry run rather than claiming the machine was cleaned.
#   2. Default run (--yes): watchdog booted out BEFORE the worker, both
#      plists and the worker root gone, container stopped then removed,
#      licence key gone - and the volume, machine-id and models KEPT.
#   3. --purge-data --yes: volume removed, ~/.cache/neohive and ~/.neohive
#      gone.
#   4. Clean machine: exits 0 with "Nothing to remove", nothing destructive.
#   5. No --yes and no terminal (NEOHIVE_TTY points at nothing): refuses
#      with E207 and changes nothing - the curl | bash safety.
#   6. Interactive "n" at the first question: aborts, changes nothing.
#   7. Interactive --purge-data with the wrong volume name typed: the
#      standard teardown runs but the volume and fingerprint survive.
#   8. Piped in with no script file, the shape `curl ... | bash` produces:
#      the banner and plan still print, and the confirmation still reads
#      the terminal rather than eating the script off stdin.
#
# The fakes read FAKE_* variables (not HAVE_*: uninstall.sh owns those
# names and exports would collide). No network, no Docker. Exit 0 when
# every expectation holds.

set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT="$PWD/uninstall.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/neohive-uninstall-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls.log"
SHIM="$WORK/bin"
ANSWERS="$WORK/answers"
mkdir -p "$SHIM"

# -- Fakes ----------------------------------------------------------------
cat > "$SHIM/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$CALLS"
case "$1" in
  info) exit 0 ;;
  ps)
    [ "$FAKE_HAVE_CONTAINER" = "1" ] || exit 0
    case "$*" in
      *" -a "*) echo "neohive" ;;
      *) [ "$FAKE_CONTAINER_RUNNING" = "1" ] && echo "neohive" ;;
    esac
    exit 0 ;;
  volume)
    case "$2" in
      inspect) [ "$FAKE_HAVE_VOLUME" = "1" ] && exit 0 || exit 1 ;;
      rm) exit 0 ;;
    esac ;;
  stop|rm) exit 0 ;;
esac
exit 0
EOF
cat > "$SHIM/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "launchctl $*" >> "$CALLS"
if [ "$1" = "list" ] && [ "$FAKE_HAVE_AGENTS" = "1" ]; then
  printf '123\t0\tcom.neohive.metal-worker\n456\t0\tcom.neohive.metal-worker-watchdog\n'
fi
exit 0
EOF
cat > "$SHIM/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -m) echo arm64 ;; *) echo Darwin ;; esac
EOF
chmod +x "$SHIM"/*
export CALLS

seed_home() {
  # A machine with everything installed.
  export HOME="$WORK/home"
  rm -rf "$HOME"
  mkdir -p "$HOME/.cache/neohive" "$HOME/.neohive/metal-worker/current/bin" "$HOME/.neohive/models" "$HOME/.neohive/logs" "$HOME/Library/LaunchAgents"
  echo "LICENSE" > "$HOME/.cache/neohive/license-key"
  echo "fingerprint-uuid" > "$HOME/.cache/neohive/machine-id"
  echo "v1.7.0" > "$HOME/.neohive/metal-worker/current/VERSION"
  echo "model" > "$HOME/.neohive/models/model.gguf"
  : > "$HOME/Library/LaunchAgents/com.neohive.metal-worker.plist"
  : > "$HOME/Library/LaunchAgents/com.neohive.metal-worker-watchdog.plist"
  export FAKE_HAVE_CONTAINER=1 FAKE_CONTAINER_RUNNING=1 FAKE_HAVE_VOLUME=1 FAKE_HAVE_AGENTS=1
  unset XDG_CACHE_HOME
  : > "$CALLS"
}

run_uninstall() { PATH="$SHIM:$PATH" bash "$SCRIPT" "$@"; }

pass=0; failures=0
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then printf 'ok   %s\n' "$desc"; pass=$((pass + 1))
  else printf 'FAIL %s\n' "$desc" >&2; failures=$((failures + 1)); fi
}
calls_have() { grep -qE -- "$1" "$CALLS"; }
calls_lack() { ! grep -qE -- "$1" "$CALLS"; }
out_lacks() { ! grep -q -- "$1" <<<"$OUT"; }
order() { # order <earlier-regex> <later-regex> - both present, earlier first
  local a b
  a="$(grep -nE -- "$1" "$CALLS" | head -1 | cut -d: -f1)"
  b="$(grep -nE -- "$2" "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
UID_NOW="$(id -u)"
WORKER_BOOTOUT="^launchctl bootout gui/$UID_NOW/com\\.neohive\\.metal-worker$"
WATCHDOG_BOOTOUT="^launchctl bootout gui/$UID_NOW/com\\.neohive\\.metal-worker-watchdog$"

# -- 1. dry run ------------------------------------------------------------
printf '\n-- 1. --dry-run --yes\n'
seed_home
OUT="$(run_uninstall --dry-run --yes 2>&1)"
check "plan names the worker"        grep -q "Metal embedding worker" <<<"$OUT"
check "plan names the container"     grep -q "Container 'neohive' (running)" <<<"$OUT"
check "plan says volume is kept"     grep -q "Kept (pass --purge-data" <<<"$OUT"
check "no launchctl bootout"         calls_lack "^launchctl bootout"
check "no docker rm"                 calls_lack "^docker rm"
check "worker files still there"     test -f "$HOME/.neohive/metal-worker/current/VERSION"
check "licence key still there"      test -f "$HOME/.cache/neohive/license-key"
check "signs off as a dry run"       grep -q "Nothing on this machine was changed" <<<"$OUT"
check "never claims removal"         out_lacks "has been removed from this machine"
check "no sign-off on skipped work"  out_lacks "container removed"

# -- 2. default teardown ----------------------------------------------------
printf '\n-- 2. --yes (default: keep data)\n'
seed_home
OUT="$(run_uninstall --yes 2>&1)"
check "watchdog booted out"            calls_have "$WATCHDOG_BOOTOUT"
check "worker booted out"              calls_have "$WORKER_BOOTOUT"
check "watchdog before worker"         order "$WATCHDOG_BOOTOUT" "$WORKER_BOOTOUT"
check "worker plist removed"           test ! -e "$HOME/Library/LaunchAgents/com.neohive.metal-worker.plist"
check "watchdog plist removed"         test ! -e "$HOME/Library/LaunchAgents/com.neohive.metal-worker-watchdog.plist"
check "worker root removed"            test ! -e "$HOME/.neohive/metal-worker"
check "container stopped"              calls_have "^docker stop --time 30 neohive$"
check "container removed"              calls_have "^docker rm -f neohive$"
check "stop before rm"                 order "^docker stop" "^docker rm -f"
check "real run claims removal"        grep -q "has been removed from this machine" <<<"$OUT"
check "real run signs off per step"    grep -q "container removed" <<<"$OUT"
check "licence key removed"            test ! -e "$HOME/.cache/neohive/license-key"
check "volume KEPT"                    calls_lack "^docker volume rm"
check "machine-id KEPT"                test -f "$HOME/.cache/neohive/machine-id"
check "models KEPT"                    test -f "$HOME/.neohive/models/model.gguf"

# -- 3. purge ---------------------------------------------------------------
printf '\n-- 3. --purge-data --yes\n'
seed_home
run_uninstall --purge-data --yes >/dev/null 2>&1
check "volume removed"                 calls_have "^docker volume rm neohive-data$"
check "cache dir removed"              test ! -e "$HOME/.cache/neohive"
# shellcheck disable=SC2088  # the tilde is in the label text, not in a path
check "~/.neohive removed"             test ! -e "$HOME/.neohive"
check "container removed"              calls_have "^docker rm -f neohive$"

# -- 4. clean machine -------------------------------------------------------
printf '\n-- 4. nothing installed\n'
seed_home
rm -rf "$HOME/.cache/neohive" "$HOME/.neohive" "$HOME/Library/LaunchAgents"/*
export FAKE_HAVE_CONTAINER=0 FAKE_CONTAINER_RUNNING=0 FAKE_HAVE_VOLUME=0 FAKE_HAVE_AGENTS=0
: > "$CALLS"
set +e; OUT="$(run_uninstall --yes 2>&1)"; rc=$?; set -e
check "exit 0"                         test "$rc" -eq 0
check "says nothing to remove"         grep -q "Nothing to remove" <<<"$OUT"
check "no destructive docker call"     calls_lack "^docker (rm|stop|volume rm)"

# -- 5. no --yes, no terminal ------------------------------------------------
printf '\n-- 5. no --yes, no terminal available\n'
seed_home
set +e
OUT="$(NEOHIVE_TTY="$WORK/no-such-tty" run_uninstall --purge-data 2>&1 </dev/null)"
rc=$?
set -e
check "refuses with E207"              grep -q "E207" <<<"$OUT"
check "non-zero exit"                  test "$rc" -ne 0
check "nothing removed"                test -f "$HOME/.cache/neohive/license-key"
check "no docker rm"                   calls_lack "^docker rm"

# -- 6. interactive: answer no ------------------------------------------------
printf '\n-- 6. interactive, answers n\n'
seed_home
printf 'n\n' > "$ANSWERS"
OUT="$(NEOHIVE_TTY="$ANSWERS" run_uninstall 2>&1 </dev/null)"
check "prints the plan first"          grep -q "This will remove" <<<"$OUT"
check "says aborted"                   grep -q "Aborted" <<<"$OUT"
check "worker still there"             test -f "$HOME/.neohive/metal-worker/current/VERSION"
check "no docker rm"                   calls_lack "^docker rm"

# -- 7. interactive purge, wrong volume name ---------------------------------
printf '\n-- 7. interactive --purge-data, wrong volume name typed\n'
seed_home
# yes to continue, no to the backup offer, then a wrong name at the typed gate
printf 'y\nn\nnot-the-volume\n' > "$ANSWERS"
set +e; OUT="$(NEOHIVE_TTY="$ANSWERS" run_uninstall --purge-data 2>&1 </dev/null)"; rc=$?; set -e
check "exit 0"                         test "$rc" -eq 0
check "offered a backup"               grep -q "Back up your data first" <<<"$OUT"
check "warned about the mismatch"      grep -q "did not match" <<<"$OUT"
check "container still removed"        calls_have "^docker rm -f neohive$"
check "volume KEPT"                    calls_lack "^docker volume rm"
check "machine-id KEPT"                test -f "$HOME/.cache/neohive/machine-id"
check "licence key removed"            test ! -e "$HOME/.cache/neohive/license-key"

# -- 8. piped in, no script file ---------------------------------------------
printf '\n-- 8. piped into bash, the shape curl | bash produces\n'
# Every case above hands bash a path, so $0 and BASH_SOURCE[0] both name a real
# file and a read of either passes. Piping removes that file: BASH_SOURCE[0] is
# unset, which under `set -u` aborts the script before the banner, and stdin is
# the script text, so a prompt that reads stdin swallows the rest of itself.
# `cat` rather than a `< "$SCRIPT"` redirect on purpose: the redirect gives bash
# a seekable file, and only the pipe reproduces what curl hands it.
# shellcheck disable=SC2002  # the cat is the point: only it makes stdin a pipe
run_piped() { cat "$SCRIPT" | PATH="$SHIM:$PATH" bash -s -- "$@"; }

seed_home
# set +e so a script that dies on the missing file reports as failed checks
# below rather than taking this harness down with it and naming nothing.
set +e; OUT="$(run_piped --dry-run --yes 2>&1)"; set -e
check "banner prints when piped"       grep -q "NeoHive uninstaller" <<<"$OUT"
check "plan prints when piped"         grep -q "This will remove" <<<"$OUT"
check "no unbound variable"            out_lacks "unbound variable"
check "dry run removed nothing"        test -f "$HOME/.cache/neohive/license-key"

seed_home
printf 'n\n' > "$ANSWERS"
set +e; OUT="$(NEOHIVE_TTY="$ANSWERS" run_piped 2>&1)"; set -e
check "prompt reads the terminal"      grep -q "Aborted" <<<"$OUT"
check "answering n removed nothing"    test -f "$HOME/.cache/neohive/license-key"

printf '\n%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ]
