#!/usr/bin/env bash
# Exercise backup.sh without Docker. A PATH shim fakes docker (and curl for
# the /health wait) and logs every call; the fake `docker cp` materialises a
# snapshot so a real archive is built, and the rest of the run is asserted
# on the archive and the call log:
#
#   backup
#     1. no container      -> E606, nothing written
#     2. container stopped -> E607, nothing written
#    2b. empty snapshot    -> E619, nothing written
#     3. happy path        -> archive with manifest.json, SHA256SUMS, data/;
#                             checksums verify with the host tool. The fake
#                             snapshot holds a path with spaces in it, so
#                             every case below carries one too
#   restore
#     4. not a backup      -> E613, no docker stop
#     5. wrong format      -> E614, no docker stop
#     6. tampered file     -> E615, no docker stop
#    6b. file missing from the checksum list, manifest count intact
#                          -> E622, no docker stop
#    6c. manifest count of zero -> E622, no docker stop
#     7. wrong volume name -> "Nothing was changed", no docker stop
#     8. happy path (--yes)-> stop, then run --rm on the container's own
#                             image with the volume and the extracted data
#                             mounted, counting the source before deleting
#                             anything, then start; health waited on
#    8b. container sees an empty /restore-source (exit 9)
#                          -> E623, container left stopped
#    8c. the restore body run directly under /bin/sh, against real
#                             directories: an empty source refuses and leaves
#                             the target alone, a full one replaces it
#   piped
#     9. no script file    -> the banner still prints, the shape
#                             `curl ... | bash` produces
#
# The end-to-end copy into a real volume is test/ops-backup-roundtrip.sh,
# which needs Docker and a running install. No network here. Exit 0 when
# every expectation holds.

set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT="$PWD/backup.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/neohive-backup-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls.log"
SHIM="$WORK/bin"
OUT_DIR="$WORK/out"
ANSWERS="$WORK/answers"
mkdir -p "$SHIM" "$OUT_DIR"
export CALLS

cat > "$SHIM/docker" <<'EOF'
#!/usr/bin/env bash
# One log line per call: the snapshot and restore -c scripts span lines.
printf '%s' "docker $*" | tr '\n' ' ' | sed 's/ *$//' >> "$CALLS"; echo >> "$CALLS"
case "$1" in
  info) exit 0 ;;
  ps)
    [ "$FAKE_HAVE_CONTAINER" = "1" ] || exit 0
    case "$*" in
      *" -a "*) echo "neohive" ;;
      *) [ "$FAKE_CONTAINER_RUNNING" = "1" ] && echo "neohive" ;;
    esac
    exit 0 ;;
  inspect) echo "neohivedev/neohive:cpu"; exit 0 ;;
  exec) exit 0 ;;
  cp)
    # docker cp neohive:/tmp/neohive-snapshot/. <dest>/  -> materialise a snapshot
    dest="$3"
    [ "${FAKE_EMPTY_SNAPSHOT:-0}" = "1" ] && exit 0
    mkdir -p "$dest/hives/h1/vectors.lance" "$dest/hiveminds/m1"
    echo "gateway"   > "$dest/gateway.db"
    echo "registry"  > "$dest/hivemind.db"
    echo "hivemind"  > "$dest/hiveminds/m1/hivemind.db"
    echo "memories"  > "$dest/hives/h1/cognitive-memory.db"
    echo "vectors"   > "$dest/hives/h1/vectors.lance/data.lance"
    echo "keymaterial" > "$dest/.encryption_key"
    # A path with spaces, because that is what splits into two arguments when
    # the checksum list is built with a newline-delimited xargs.
    echo "spaced"    > "$dest/hives/h1/a name with spaces.db"
    exit 0 ;;
  run)
    # 9 is what the in-container guard exits when /restore-source is short.
    [ "${FAKE_RESTORE_GUARD_TRIP:-0}" = "1" ] && exit 9
    exit 0 ;;
  stop|start|volume) exit 0 ;;
esac
exit 0
EOF
cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"status":"ok","version":"1.7.0"}'
exit 0
EOF
chmod +x "$SHIM"/*

run_backup() { PATH="$SHIM:$PATH" NEOHIVE_HEALTH_TIMEOUT=2 bash "$SCRIPT" "$@"; }
reset() { : > "$CALLS"; export FAKE_HAVE_CONTAINER=1 FAKE_CONTAINER_RUNNING=1; }

pass=0; failures=0
check() {
  local desc="$1"; shift
  if "$@"; then printf 'ok   %s\n' "$desc"; pass=$((pass + 1))
  else printf 'FAIL %s\n' "$desc" >&2; failures=$((failures + 1)); fi
}
expect_exit0() { # expect_exit0 <rc> <output> - shows the run on failure so CI logs say why
  [ "$1" -eq 0 ] && return 0
  printf -- '--- script output (exit %s) ---\n%s\n---\n' "$1" "$2" >&2
  return 1
}
calls_have() { grep -qE -- "$1" "$CALLS"; }
out_lacks() { ! grep -q -- "$1" <<<"$OUT"; }
absent() { [ ! -e "$1" ]; }
calls_lack() { ! grep -qE -- "$1" "$CALLS"; }
order() {
  local a b
  a="$(grep -nE -- "$1" "$CALLS" | head -1 | cut -d: -f1)"
  b="$(grep -nE -- "$2" "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
no_archives() { ! find "$OUT_DIR" -name '*.tar.gz' | grep -q .; }

# -- backup ---------------------------------------------------------------------
printf '\n-- 1. backup, no container\n'
reset; export FAKE_HAVE_CONTAINER=0
set +e; OUT="$(run_backup --out "$OUT_DIR" 2>&1)"; rc=$?; set -e
check "E606"                 grep -q E606 <<<"$OUT"
check "non-zero exit"        test "$rc" -ne 0
check "nothing written"      no_archives

printf '\n-- 2. backup, container stopped\n'
reset; export FAKE_CONTAINER_RUNNING=0
set +e; OUT="$(run_backup --out "$OUT_DIR" 2>&1)"; rc=$?; set -e
check "E607"                 grep -q E607 <<<"$OUT"
check "hints docker start"   grep -q "docker start neohive" <<<"$OUT"
check "nothing written"      no_archives

printf '\n-- 2b. backup, snapshot came out empty\n'
reset; export FAKE_EMPTY_SNAPSHOT=1
set +e; OUT="$(run_backup --out "$OUT_DIR" 2>&1)"; rc=$?; set -e
unset FAKE_EMPTY_SNAPSHOT
check "E619"                 grep -q E619 <<<"$OUT"
check "non-zero exit"        test "$rc" -ne 0
check "nothing written"      no_archives

printf '\n-- 3. backup, happy path\n'
reset
set +e; OUT="$(run_backup --out "$OUT_DIR" 2>&1)"; rc=$?; set -e
check "exit 0"               expect_exit0 "$rc" "$OUT"
ARCHIVE="$(find "$OUT_DIR" -name 'neohive-backup-*.tar.gz' | head -1)"
check "archive written"      test -s "$ARCHIVE"
check "snapshot ran in container" calls_have "^docker exec neohive sh -c .*sqlite3.*snapshot /app/data$"
check "snapshot cleaned up"  calls_have "^docker exec neohive rm -rf /tmp/neohive-snapshot$"
LIST="$(tar -tzf "$ARCHIVE")"
check "manifest.json"        grep -q '/manifest.json$' <<<"$LIST"
check "SHA256SUMS"           grep -q '/SHA256SUMS$' <<<"$LIST"
check "gateway.db"           grep -q '/data/gateway.db$' <<<"$LIST"
check "per-hive db"          grep -q '/data/hives/h1/cognitive-memory.db$' <<<"$LIST"
check "lance data"           grep -q '/data/hives/h1/vectors.lance/data.lance$' <<<"$LIST"
check "encryption key"       grep -q '/data/.encryption_key$' <<<"$LIST"
check "path with spaces"     grep -q '/data/hives/h1/a name with spaces.db$' <<<"$LIST"
# shellcheck disable=SC2016  # bash -c takes its args positionally as "$1";
# the single quotes are the point
check "no macOS ._ files"    bash -c '! grep -q "/\._" <<<"$1"' _ "$LIST"
EXTRACT="$WORK/extract"; mkdir -p "$EXTRACT"; tar -C "$EXTRACT" -xzf "$ARCHIVE"
TOP="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -1)"
check "manifest format 1"    grep -q '"format": 1' "$TOP/manifest.json"
check "manifest image"       grep -q '"image": "neohivedev/neohive:cpu"' "$TOP/manifest.json"
check "manifest version"     grep -q '"neohive_version": "1.7.0"' "$TOP/manifest.json"
check "manifest file count"  grep -q '"files": 7' "$TOP/manifest.json"
if command -v sha256sum >/dev/null 2>&1; then SHA=sha256sum; else SHA="shasum -a 256"; fi
check "checksums verify"     bash -c "cd '$TOP' && $SHA -c SHA256SUMS --quiet"
# The spaced path is the one a newline-delimited xargs drops, and a list that
# drops it still verifies clean - so the line has to be asserted directly.
check "spaced path listed"   grep -qF 'data/hives/h1/a name with spaces.db' "$TOP/SHA256SUMS"
LISTED="$(wc -l < "$TOP/SHA256SUMS" | tr -d ' ')"
TREE_FILES="$(find "$TOP/data" -type f | wc -l | tr -d ' ')"
check "list covers the tree" test "$LISTED" = "$TREE_FILES"
check "prints restore hint"  grep -q -- "--restore" <<<"$OUT"

# -- restore ------------------------------------------------------------------------
printf '\n-- 4. restore, not a backup\n'
reset
mkdir -p "$WORK/junk/neohive-backup-x"; echo hi > "$WORK/junk/neohive-backup-x/readme"
tar -C "$WORK/junk" -czf "$WORK/junk.tar.gz" neohive-backup-x
set +e; OUT="$(run_backup --restore "$WORK/junk.tar.gz" --yes 2>&1)"; rc=$?; set -e
check "E613"                 grep -q E613 <<<"$OUT"
check "no docker stop"       calls_lack "^docker stop"

printf '\n-- 5. restore, unsupported format\n'
reset
rm -rf "$WORK/fmt"; mkdir -p "$WORK/fmt"; cp -R "$TOP" "$WORK/fmt/"
FMT_TOP="$WORK/fmt/$(basename "$TOP")"
sed -i.bak 's/"format": 1/"format": 2/' "$FMT_TOP/manifest.json" && rm -f "$FMT_TOP/manifest.json.bak"
tar -C "$WORK/fmt" -czf "$WORK/fmt.tar.gz" "$(basename "$TOP")"
set +e; OUT="$(run_backup --restore "$WORK/fmt.tar.gz" --yes 2>&1)"; rc=$?; set -e
check "E614"                 grep -q E614 <<<"$OUT"
check "no docker stop"       calls_lack "^docker stop"

printf '\n-- 6. restore, tampered data\n'
reset
rm -rf "$WORK/tamper"; mkdir -p "$WORK/tamper"; cp -R "$TOP" "$WORK/tamper/"
echo "corrupted" >> "$WORK/tamper/$(basename "$TOP")/data/gateway.db"
tar -C "$WORK/tamper" -czf "$WORK/tamper.tar.gz" "$(basename "$TOP")"
set +e; OUT="$(run_backup --restore "$WORK/tamper.tar.gz" --yes 2>&1)"; rc=$?; set -e
check "E615"                 grep -q E615 <<<"$OUT"
check "says nothing changed" grep -q "Nothing was changed" <<<"$OUT"
check "no docker stop"       calls_lack "^docker stop"
check "no docker run"        calls_lack "^docker run"

printf '\n-- 6b. restore, a file missing from the checksum list\n'
# The gap this closes: sha256sum -c only checks the lines it is handed, so an
# archive short of its manifest verifies clean. The data file and its line are
# both removed and the manifest count is left at 7, which is the shape a
# truncated transfer, a partial extraction or an edited manifest produces.
reset
rm -rf "$WORK/short"; mkdir -p "$WORK/short"; cp -R "$TOP" "$WORK/short/"
SHORT_TOP="$WORK/short/$(basename "$TOP")"
rm -f "$SHORT_TOP/data/hives/h1/vectors.lance/data.lance"
grep -vF 'data/hives/h1/vectors.lance/data.lance' "$SHORT_TOP/SHA256SUMS" > "$SHORT_TOP/SHA256SUMS.new"
mv "$SHORT_TOP/SHA256SUMS.new" "$SHORT_TOP/SHA256SUMS"
tar -C "$WORK/short" -czf "$WORK/short.tar.gz" "$(basename "$TOP")"
check "short archive still verifies" bash -c "cd '$SHORT_TOP' && $SHA -c SHA256SUMS --quiet"
set +e; OUT="$(run_backup --restore "$WORK/short.tar.gz" --yes 2>&1)"; rc=$?; set -e
check "E622"                 grep -q E622 <<<"$OUT"
check "non-zero exit"        test "$rc" -ne 0
check "says nothing changed" grep -q "Nothing was changed" <<<"$OUT"
check "no docker stop"       calls_lack "^docker stop"
check "no docker run"        calls_lack "^docker run"

printf '\n-- 6c. restore, manifest names zero files\n'
# manifest.json is the one file SHA256SUMS does not cover, so a damaged count
# reaches the restore unchallenged. Zero is the value that satisfies a bare
# "extracted is not fewer than expected" test and would then satisfy the
# container's count as well, which is why it is rejected on its own.
reset
rm -rf "$WORK/zero"; mkdir -p "$WORK/zero"; cp -R "$TOP" "$WORK/zero/"
ZERO_TOP="$WORK/zero/$(basename "$TOP")"
sed -i.bak 's/"files": 7/"files": 0/' "$ZERO_TOP/manifest.json" && rm -f "$ZERO_TOP/manifest.json.bak"
tar -C "$WORK/zero" -czf "$WORK/zero.tar.gz" "$(basename "$TOP")"
check "zero archive still verifies" bash -c "cd '$ZERO_TOP' && $SHA -c SHA256SUMS --quiet"
set +e; OUT="$(run_backup --restore "$WORK/zero.tar.gz" --yes 2>&1)"; rc=$?; set -e
check "E622"                 grep -q E622 <<<"$OUT"
check "non-zero exit"        test "$rc" -ne 0
check "no docker stop"       calls_lack "^docker stop"
check "no docker run"        calls_lack "^docker run"

printf '\n-- 7. restore, wrong volume name typed\n'
reset
printf 'not-the-volume\n' > "$ANSWERS"
set +e; OUT="$(NEOHIVE_TTY="$ANSWERS" run_backup --restore "$ARCHIVE" 2>&1 </dev/null)"; rc=$?; set -e
check "exit 0"               test "$rc" -eq 0
check "says nothing changed" grep -q "Nothing was changed" <<<"$OUT"
check "no docker stop"       calls_lack "^docker stop"

printf '\n-- 8. restore, happy path\n'
reset
set +e; OUT="$(run_backup --restore "$ARCHIVE" --yes 2>&1)"; rc=$?; set -e
check "exit 0"               expect_exit0 "$rc" "$OUT"
check "verified first"       grep -q "files verified" <<<"$OUT"
check "stopped container"    calls_have "^docker stop --time 60 neohive$"
check "throwaway on own image" calls_have "^docker run --rm -v neohive-data:/restore-target -v .*/data:/restore-source:ro --entrypoint sh neohivedev/neohive:cpu -c "
check "passes count and paths" calls_have "guard 7 /restore-source /restore-target$"
check "started container"    calls_have "^docker start neohive$"
check "stop before run"      order "^docker stop" "^docker run"
check "run before start"     order "^docker run" "^docker start"
check "reports healthy"      grep -q "server healthy" <<<"$OUT"

printf '\n-- 8b. restore, the container cannot see /restore-source\n'
# Exit 9 is the in-container guard refusing because the bind mount came up
# empty, which is what a container runtime that does not share the temp
# directory produces. The volume must be reported untouched and the server must
# not be started on top of it.
reset; export FAKE_RESTORE_GUARD_TRIP=1
set +e; OUT="$(run_backup --restore "$ARCHIVE" --yes 2>&1)"; rc=$?; set -e
unset FAKE_RESTORE_GUARD_TRIP
check "E623"                 grep -q E623 <<<"$OUT"
check "non-zero exit"        test "$rc" -ne 0
check "says volume untouched" grep -q "volume was left untouched" <<<"$OUT"
check "names the TMPDIR fix" grep -q "TMPDIR" <<<"$OUT"
check "says how to restart"  grep -q "docker start neohive" <<<"$OUT"
check "not E617"             out_lacks E617
check "container not started" calls_lack "^docker start"

printf '\n-- 8c. the restore body itself, run under /bin/sh\n'
# Everything above asserts the command the script builds. This runs the text it
# passes to the container, against real directories, so an inverted comparison
# in the guard fails here instead of being asserted around. RESTORE_SCRIPT is
# read from a subshell so sourcing backup.sh cannot disturb the cases above.
RESTORE_SCRIPT="$(NEOHIVE_LIB_ONLY=1 bash -c '. "$1"; printf "%s" "$RESTORE_SCRIPT"' _ "$SCRIPT")"
check "body was read"        test -n "$RESTORE_SCRIPT"
G="$WORK/guard"; mkdir -p "$G/src/sub" "$G/empty" "$G/tgt"
echo one > "$G/src/one.db"; echo two > "$G/src/sub/two with space.db"
echo keep > "$G/tgt/existing.db"
set +e; GOUT="$(sh -c "$RESTORE_SCRIPT" guard 2 "$G/empty" "$G/tgt" 2>&1)"; grc=$?; set -e
check "empty source exits 9" test "$grc" -eq 9
check "reports what it saw"  grep -q "holds 0 files, expected 2" <<<"$GOUT"
check "target left alone"    test -f "$G/tgt/existing.db"
set +e; sh -c "$RESTORE_SCRIPT" guard 2 "$G/src" "$G/tgt" >/dev/null 2>&1; grc=$?; set -e
check "full source exits 0"  test "$grc" -eq 0
check "stale file removed"   absent "$G/tgt/existing.db"
check "spaced path copied"   test -f "$G/tgt/sub/two with space.db"

printf '\n-- 9. piped into bash, the shape curl | bash produces\n'
# Every case above hands bash a path, so BASH_SOURCE[0] names a real file and a
# read of it passes. Piping leaves it unset, which under `set -u` aborts before
# the banner. `cat` rather than a redirect on purpose: the redirect gives bash a
# seekable file, and only the pipe reproduces what curl hands it.
reset
# shellcheck disable=SC2002  # the cat is the point: only it makes stdin a pipe
run_piped() { cat "$SCRIPT" | PATH="$SHIM:$PATH" bash -s -- "$@"; }
set +e; OUT="$(run_piped --help 2>&1)"; rc=$?; set -e
check "exit 0"               expect_exit0 "$rc" "$OUT"
check "usage still prints"   grep -q "Usage: backup.sh" <<<"$OUT"

printf '\n%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ]
