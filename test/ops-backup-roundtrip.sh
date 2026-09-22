#!/usr/bin/env bash
# Real backup -> restore round trip against a running NeoHive container.
# Needs Docker and an install to point at; it is NOT run by CI because it
# takes a live container and restarts it. Run it against a throwaway
# install (test/smoke.sh leaves one on port 13577 under the name neohive),
# never against one whose data you care about.
#
#   NEOHIVE_CONTAINER_NAME=neohive NEOHIVE_PORT=13577 bash test/ops-backup-roundtrip.sh
#
# What it proves:
#   1. backup.sh produces an archive whose SHA256SUMS verify on the host;
#   2. every SQLite file in the archive opens and passes PRAGMA integrity_check
#      (the .backup copies are whole databases, not raw file copies);
#   3. a marker written into the volume AFTER the backup is gone after the
#      restore, and the container comes back healthy - the restore really
#      replaced the volume contents;
#   4. a path with spaces in it survives the whole round trip. This is the
#      path the checksum step drops if its file list is not NUL-delimited,
#      and the stubbed suite covers it too - here it goes through real
#      sqlite3, tar and docker cp.

set -euo pipefail

cd "$(dirname "$0")/.."
: "${NEOHIVE_CONTAINER_NAME:=neohive}"
: "${NEOHIVE_PORT:=3577}"
export NEOHIVE_CONTAINER_NAME NEOHIVE_PORT

command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$NEOHIVE_CONTAINER_NAME" \
  || { echo "container $NEOHIVE_CONTAINER_NAME is not running" >&2; exit 1; }
VOLUME="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}' "$NEOHIVE_CONTAINER_NAME")"
[ -n "$VOLUME" ] || { echo "could not find the /app/data volume" >&2; exit 1; }
export NEOHIVE_VOLUME_NAME="$VOLUME"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/neohive-roundtrip.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "-- 0. plant a path with spaces in the volume --"
# A real database, not a text file: this way the spaces go through sqlite3's
# .backup inside the container as well as through tar, docker cp and the
# checksum list. A non-database file with a .db name would fail the snapshot.
SPACED='/app/data/a spaced hive.db'
docker exec "$NEOHIVE_CONTAINER_NAME" sh -c 'sqlite3 "$1" "create table if not exists t(x); insert into t values (1);"' _ "$SPACED"
docker exec "$NEOHIVE_CONTAINER_NAME" test -s "$SPACED"
echo "planted $SPACED"

echo "-- 1. backup --"
bash ./backup.sh --out "$WORK"
ARCHIVE="$(find "$WORK" -name 'neohive-backup-*.tar.gz' | head -1)"
[ -s "$ARCHIVE" ]
mkdir -p "$WORK/x"; tar -C "$WORK/x" -xzf "$ARCHIVE"
TOP="$(find "$WORK/x" -mindepth 1 -maxdepth 1 -type d)"
if command -v sha256sum >/dev/null 2>&1; then ( cd "$TOP" && sha256sum -c SHA256SUMS --quiet ); else ( cd "$TOP" && shasum -a 256 -c SHA256SUMS --quiet ); fi
echo "checksums verify"

echo "-- 2. every SQLite file is a whole database --"
# Check inside the container image so sqlite3 is guaranteed to be there.
docker run --rm -v "$TOP/data:/chk:ro" --entrypoint sh "$(docker inspect --format '{{.Config.Image}}' "$NEOHIVE_CONTAINER_NAME")" -c '
  set -e; n=0
  # The list goes via a file rather than a pipe so the counter survives, and
  # read keeps each path whole - a for loop over $(find) would split "a
  # spaced hive.db" into three names that do not exist.
  find /chk -name "*.db" > /tmp/dbs
  while IFS= read -r db; do
    r="$(sqlite3 "$db" "PRAGMA integrity_check;")"
    [ "$r" = "ok" ] || { echo "integrity_check failed: $db -> $r"; exit 1; }
    n=$((n+1))
  done < /tmp/dbs
  echo "$n databases ok"'

echo "-- 3. restore replaces the volume --"
docker exec "$NEOHIVE_CONTAINER_NAME" sh -c 'echo marker > /app/data/ROUNDTRIP-MARKER'
docker exec "$NEOHIVE_CONTAINER_NAME" test -f /app/data/ROUNDTRIP-MARKER
bash ./backup.sh --restore "$ARCHIVE" --yes
if docker exec "$NEOHIVE_CONTAINER_NAME" test -f /app/data/ROUNDTRIP-MARKER; then
  echo "marker survived the restore: the volume was not replaced" >&2; exit 1
fi
curl -fsS "http://localhost:$NEOHIVE_PORT/health" >/dev/null
echo "marker gone, server healthy"

echo "-- 4. the path with spaces came back --"
docker exec "$NEOHIVE_CONTAINER_NAME" test -s "$SPACED" \
  || { echo "the spaced path did not survive the round trip: $SPACED" >&2; exit 1; }
docker exec "$NEOHIVE_CONTAINER_NAME" sh -c 'sqlite3 "$1" "select count(*) from t;"' _ "$SPACED" >/dev/null \
  || { echo "the restored spaced database does not open: $SPACED" >&2; exit 1; }
echo "spaced path restored and opens"
# Planted by step 0 and carried back by the restore, so it has to be removed or
# it stays in the install for good - the marker is the only thing step 3 clears.
docker exec "$NEOHIVE_CONTAINER_NAME" rm -f "$SPACED"
echo "planted database cleaned up"
echo
echo "ROUND TRIP OK"
