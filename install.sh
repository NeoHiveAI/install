#!/usr/bin/env bash
#
# NeoHive installer.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh)
#
# Environment overrides (all optional):
#   NEOHIVE_BACKEND            - force backend: cpu|vulkan|cuda|rocm (default: autodetect)
#   NEOHIVE_PORT               - port to publish (default: 3577)
#   NEOHIVE_LICENSE_FILE       - path to your NeoHive license file (.key or .json).
#                                Equivalent to passing --license-file. The installer
#                                also auto-detects license.json / license.key in the
#                                current working directory and alongside install.sh
#                                if no flag / env var is provided. Interactive mode
#                                prompts for the path when no source resolves.
#   NEOHIVE_LICENSE_KEY        - raw license key. Set by apply_license_file after
#                                reading whichever source resolved, but operators
#                                can also export it directly for non-file workflows.
#   NEOHIVE_ROTATE_LICENSE     - set to 1 to force re-read of the license file
#                                even when the cached key is present
#   NEOHIVE_UPDATE_REPO        - override the Docker Hub repo for in-app update
#                                checks (default: neohivedev/neohive)
#   NEOHIVE_PDF_BRIDGE_TIMEOUT_MS  - docling PDF bridge per-document timeout in ms
#                                    (default 300000 = 5 min). Raise this for very
#                                    large PDFs - a 900-page document can need
#                                    25-30 minutes. Example: 1800000 (30 min).
#                                    Forwarded as MEMVEC_PDF_BRIDGE_TIMEOUT_MS.
#   NEOHIVE_PDF_WARMUP_TIMEOUT_MS  - docling model-warmup timeout in ms (default
#                                    300000 = 5 min). Raise this on first-boot
#                                    hosts that pay a slow HuggingFace download.
#                                    Forwarded as MEMVEC_PDF_WARMUP_TIMEOUT_MS.
#   NEOHIVE_CHUNKER_TIMEOUT_MS     - markdown/code chunker subprocess timeout in
#                                    ms (default 30000). Distinct from the PDF
#                                    bridge timeout above - this gates the
#                                    chonkie/Rust splitter, not docling.
#                                    Forwarded as MEMVEC_CHUNKER_TIMEOUT_MS.
#
# The license key extracted from NEOHIVE_LICENSE_FILE is cached at
# $XDG_CACHE_HOME/neohive/license-key (or ~/.cache/neohive/ if XDG is unset)
# with mode 0600 so the customer does not re-supply on upgrade. Re-running
# the script is the supported upgrade path. The Docker Hub image is public,
# so no registry access token is required.
#
# The server serves plain HTTP on a single port. Customers who need TLS
# wrap their MCP endpoint with the mcp-remote npm package on the client
# side - no server-side TLS work.

set -euo pipefail

IMAGE="docker.io/neohivedev/neohive"
# Repository path used by the Docker Hub Hub API for tag enumeration. Kept
# in lockstep with $IMAGE so a future rename only needs one edit here.
DOCKERHUB_REPO="neohivedev/neohive"
CONTAINER_NAME="neohive"
VOLUME_NAME="neohive-data"
DEFAULT_PORT=3577
HEALTH_TIMEOUT_SECONDS=60

# Keygen account + product UUIDs baked at Phase 0 dashboard setup.
# Account scopes the API namespace; product is required by Keygen's
# validate-key when the policy is configured with product scope
# (default for our setup). Both are non-secret - they appear in URL
# paths and validation payloads.
KEYGEN_ACCOUNT_ID="90b10ef0-ed7d-40ce-a1d4-21d568fdb574"
KEYGEN_PRODUCT_ID="386b2255-8b79-4358-9e12-aaf3b3c17aa2"

# Pre-release tag pattern. Applied at every point the installer can
# resolve a versioned tag - at registry enumeration time
# (list_versioned_tags) and at pull time (try_pull_tag). Defining it
# once and reusing it makes pre-release rejection an invariant of the
# resolver: a future code path that hand-rolls version tags cannot
# bypass the filter by skipping list_versioned_tags. This is what
# lets the upstream release pipeline publish arm64 RC builds
# (v<X>-cpu-arm64) without leaking them to Apple Silicon customers.
PRERELEASE_TAG_PATTERN='-(rc|beta|alpha|pre|dev)'

# CHANGELOG.md in this repo, surfaced post-install on upgrades.
CHANGELOG_RAW_URL="https://raw.githubusercontent.com/NeoHiveAI/install/main/CHANGELOG.md"
CHANGELOG_VIEW_URL="https://github.com/NeoHiveAI/install/blob/main/CHANGELOG.md"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/neohive"
LICENSE_CACHE_FILE="$CACHE_DIR/license-key"
PORT="${NEOHIVE_PORT:-$DEFAULT_PORT}"

# Detected once near boot, before docker rm/run rewrite the world.
# Presence of the data volume is a more durable signal than the container
# being alive: a previous `docker rm` would have removed the container
# but the volume persists across reinstalls.
RELEASE_VERSION=""
RELEASE_OVERVIEW=""

# -- Colour palette ----------------------------------------------------
# 256-colour ANSI. Terminals without 256-colour support fall through
# to the rendering they can manage. When stdout is not a TTY (piped
# into a file, for instance) colours are disabled entirely so the
# output stays readable.
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_VIOLET=$'\033[38;5;99m'     # primary hex - approximates #7C3AED
  C_LAVENDER=$'\033[38;5;147m'  # secondary hex - approximates #A78BFA
  C_ORCHID=$'\033[38;5;177m'    # tertiary hex - approximates #C084FC
  C_CYAN=$'\033[38;5;81m'
  C_GREEN=$'\033[38;5;78m'
  C_RED=$'\033[38;5;203m'
  C_YELLOW=$'\033[38;5;221m'
else
  C_RESET='' C_BOLD='' C_DIM=''
  C_VIOLET='' C_LAVENDER='' C_ORCHID=''
  C_CYAN='' C_GREEN='' C_RED='' C_YELLOW=''
fi

# -- Banner ------------------------------------------------------------
# Three-hexagon cluster (violet / lavender / orchid) beside the NeoHive
# wordmark. No emoji characters, no Unicode box-drawing - pure ASCII.
print_banner() {
  # shellcheck disable=SC2028  # intentional ANSI escape sequences in printf
  printf '\n'
  printf '    %s __%s         %s _   _            _   _ _%s\n'          "$C_VIOLET"  "$C_RESET" "$C_BOLD" "$C_RESET"
  printf '    %s/  \\%s%s__%s     %s| \\ | | ___  ___ | | | (_)_   _____%s\n'   "$C_VIOLET" "$C_RESET" "$C_LAVENDER" "$C_RESET" "$C_BOLD" "$C_RESET"
  printf '    %s\\__/%s%s  \\%s    %s|  \\| |/ _ \\/ _ \\| |_| | \\ \\ / / _ \\%s\n' "$C_VIOLET" "$C_RESET" "$C_LAVENDER" "$C_RESET" "$C_BOLD" "$C_RESET"
  printf '    %s/  \\%s%s__/%s    %s| |\\  |  __/ (_) |  _  | |\\ V /  __/%s\n'   "$C_ORCHID" "$C_RESET" "$C_LAVENDER" "$C_RESET" "$C_BOLD" "$C_RESET"
  printf '    %s\\__/%s         %s|_| \\_|\\___|\\___/|_| |_|_| \\_/ \\___|%s\n' "$C_ORCHID" "$C_RESET" "$C_BOLD" "$C_RESET"
  printf '\n'
  printf '    %sSemantic Memory Platform%s\n'       "$C_DIM" "$C_RESET"
  printf '    %s=========================%s\n\n'     "$C_DIM" "$C_RESET"
}

# -- Logging helpers --------------------------------------------------
# step()  - "[N] Message..."
# info()  - indented informational line
# ok()    - indented OK marker, optional trailing detail
# warn()  - indented WARN marker (stderr)
# fail()  - indented FAIL marker (stderr) with error code, exits 1
#           Usage: fail Exxx "message"
#           Code scheme:
#             E1xx = build/release bug (placeholder config, missing baked-in IDs)
#             E2xx = user environment (OS, docker, TTY, bad backend)
#             E3xx = license (rejected, empty, missing/unreadable file)
#             E4xx = registry (Docker Hub API failures, rate limits)
#             E5xx = image resolution / pull
#             E6xx = runtime (health timeout, machine-id, env vars)
step() {
  printf '%s[%d]%s %s\n' "$C_CYAN" "$1" "$C_RESET" "$2"
}
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

# -- LAN IP detection -------------------------------------------------
# Best-effort: returns the primary non-loopback IPv4 so users installing
# on a remote/shared box (not their laptop) know which address to open
# in the browser. Empty string if detection fails - we just skip that
# line rather than print a misleading value.
detect_lan_ip() {
  local ip=""
  case "$(uname -s)" in
    Darwin)
      ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
      [ -z "$ip" ] && ip="$(ipconfig getifaddr en1 2>/dev/null || true)"
      ;;
    Linux)
      if command -v hostname >/dev/null 2>&1; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
      fi
      if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
      fi
      ;;
  esac
  printf '%s' "$ip"
}

# -- Post-install summary ---------------------------------------------
# The "Next steps" block is intentionally first and visually loudest -
# the customer's next action is to open the dashboard and finish
# onboarding in the browser, so everything else (MCP details, docker
# commands, upgrade notes) is reference material beneath it.
print_post_install() {
  local line lan_ip
  line=$(printf '%*s' 67 '' | tr ' ' '-')
  lan_ip="$(detect_lan_ip)"

  printf '\n   %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
  printf '   %s%sNeoHive is running.%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"

  printf '   %s>> NEXT STEP: open the dashboard to finish onboarding <<%s\n\n' "$C_BOLD$C_VIOLET" "$C_RESET"
  printf '     On this machine:    %shttp://localhost:%s%s\n' "$C_CYAN" "$PORT" "$C_RESET"
  if [ -n "$lan_ip" ]; then
    printf '     From another host:  %shttp://%s:%s%s\n' "$C_CYAN" "$lan_ip" "$PORT" "$C_RESET"
  else
    printf '     From another host:  %shttp://<this-machine-ip>:%s%s\n' "$C_CYAN" "$PORT" "$C_RESET"
  fi
  printf '\n'
  printf '   In the dashboard you will:\n'
  printf '     1. Create your first project (a "hive").\n'
  printf '     2. Copy the generated MCP command into your editor config.\n'
  printf '     3. Start storing and recalling memories from any MCP client.\n\n'

  printf '   %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
  printf '   %sReference%s\n\n' "$C_BOLD" "$C_RESET"
  printf '     MCP endpoint:   %shttp://localhost:%s/hiveminds/<id>/mcp%s\n' "$C_CYAN" "$PORT" "$C_RESET"
  printf '                     (the <id> is shown on the project detail page)\n\n'
  printf '     HTTPS/remote:   wrap the endpoint with the %smcp-remote%s npm\n' "$C_BOLD" "$C_RESET"
  printf '                     package on the client (copy-paste command is\n'
  printf '                     shown in the dashboard).\n\n'
  printf '     Container ops:\n'
  printf '       %sdocker logs -f %s%s\n' "$C_DIM" "$CONTAINER_NAME" "$C_RESET"
  printf '       %sdocker restart %s%s\n' "$C_DIM" "$CONTAINER_NAME" "$C_RESET"
  printf '\n'
  printf '     Upgrade:        re-run this installer (cached license is reused).\n'
  printf '     Rotate license: %sNEOHIVE_ROTATE_LICENSE=1 bash <(curl ...)%s\n' "$C_DIM" "$C_RESET"
  printf '   %s%s%s\n\n' "$C_DIM" "$line" "$C_RESET"
}

# -- Release notes (used on upgrade) ----------------------------------
# Best-effort fetch of CHANGELOG.md from this repo and extraction of the
# first version section's "### Release overview" body. On any failure
# (no network, 404, malformed file) we silently fall back to the generic
# post-install summary so a flaky fetch never breaks an upgrade.
fetch_latest_release_notes() {
  local md
  md="$(curl -fsSL --max-time 10 "$CHANGELOG_RAW_URL" 2>/dev/null)" || return 1
  [ -n "$md" ] || return 1
  # awk parses the FIRST `## v?X.Y.Z` section and extracts the body of
  # the `### Release overview` block within it. Stops at the next ## or
  # ### heading so we capture exactly one overview.
  local parsed
  parsed="$(
    printf '%s\n' "$md" | awk '
      BEGIN { ver = ""; in_ovr = 0 }
      /^## v?[0-9]+\.[0-9]+\.[0-9]+/ {
        if (ver != "") exit
        if (match($0, /v?[0-9]+\.[0-9]+\.[0-9]+/)) {
          ver = substr($0, RSTART, RLENGTH)
        }
        print "VERSION:" ver
        next
      }
      /^### Release overview/ { in_ovr = 1; next }
      /^(## |### )/ { if (in_ovr) in_ovr = 0 }
      in_ovr { print "BODY:" $0 }
    '
  )"
  [ -n "$parsed" ] || return 1
  RELEASE_VERSION="$(printf '%s\n' "$parsed" | sed -n 's/^VERSION://p' | head -n1)"
  RELEASE_OVERVIEW="$(printf '%s\n' "$parsed" | sed -n 's/^BODY://p')"
  # Trim leading and trailing blank lines from the overview body.
  RELEASE_OVERVIEW="$(printf '%s' "$RELEASE_OVERVIEW" | awk 'NF { found=1 } found' | sed -e :a -e '/^$/{$d;N;ba' -e '}')"
  [ -n "$RELEASE_VERSION" ] && [ -n "$RELEASE_OVERVIEW" ]
}

# Post-install summary variant for upgrades. Replaces the "Next step:
# create your first project" block (wrong for an upgrade) with release
# notes for the version that was just pulled, plus a link to the full
# changelog. Falls back to the generic summary if release notes are
# unavailable.
print_post_install_update() {
  if ! fetch_latest_release_notes; then
    # CHANGELOG fetch failed - still announce the upgrade but skip notes.
    local line lan_ip
    line=$(printf '%*s' 67 '' | tr ' ' '-')
    lan_ip="$(detect_lan_ip)"
    printf '\n   %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
    printf '   %s%sNeoHive updated.%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf '     %sRelease notes unavailable (fetch failed). See:%s\n' "$C_DIM" "$C_RESET"
    printf '     %s%s%s\n\n' "$C_CYAN" "$CHANGELOG_VIEW_URL" "$C_RESET"
    printf '     Dashboard:  %shttp://localhost:%s%s\n' "$C_CYAN" "$PORT" "$C_RESET"
    [ -n "$lan_ip" ] && printf '     LAN:        %shttp://%s:%s%s\n' "$C_CYAN" "$lan_ip" "$PORT" "$C_RESET"
    printf '   %s%s%s\n\n' "$C_DIM" "$line" "$C_RESET"
    return
  fi

  local line lan_ip
  line=$(printf '%*s' 67 '' | tr ' ' '-')
  lan_ip="$(detect_lan_ip)"

  printf '\n   %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
  printf '   %s%sNeoHive updated to %s.%s\n\n' "$C_BOLD" "$C_GREEN" "$RELEASE_VERSION" "$C_RESET"

  printf '   %s%sWhat'\''s new%s\n\n' "$C_BOLD" "$C_VIOLET" "$C_RESET"
  # Indent each overview line by 5 spaces so it sits inside the framed block.
  printf '%s\n' "$RELEASE_OVERVIEW" | sed 's/^/     /'
  printf '\n'
  printf '     Full changelog: %s%s%s\n\n' "$C_CYAN" "$CHANGELOG_VIEW_URL" "$C_RESET"

  printf '   Dashboard:  %shttp://localhost:%s%s\n' "$C_CYAN" "$PORT" "$C_RESET"
  if [ -n "$lan_ip" ]; then
    printf '   LAN:        %shttp://%s:%s%s\n' "$C_CYAN" "$lan_ip" "$PORT" "$C_RESET"
  fi
  printf '\n'

  printf '   %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
  printf '   %sReference%s\n\n' "$C_BOLD" "$C_RESET"
  printf '     Container ops:\n'
  printf '       %sdocker logs -f %s%s\n' "$C_DIM" "$CONTAINER_NAME" "$C_RESET"
  printf '       %sdocker restart %s%s\n\n' "$C_DIM" "$CONTAINER_NAME" "$C_RESET"
  printf '     Rotate license: %sNEOHIVE_ROTATE_LICENSE=1 bash <(curl ...)%s\n' "$C_DIM" "$C_RESET"
  printf '   %s%s%s\n\n' "$C_DIM" "$line" "$C_RESET"
}

# -- Backend fallback chain -------------------------------------------
# Each detected backend tries to pull its matching image; on a missing
# tag we degrade along this chain and re-try. The CPU image is the
# universal fallback - every release ships one. If the whole chain
# misses on the floating tags (:rocm, :cuda, etc.) we enumerate
# versioned tags (vX.Y.Z-<backend>) from the registry and repeat the
# walk so a partial release (e.g. only CPU built at HEAD) still yields
# a working install.
backend_chain() {
  case "$1" in
    rocm)   printf 'rocm vulkan cpu' ;;
    cuda)   printf 'cuda vulkan cpu' ;;
    vulkan) printf 'vulkan cpu' ;;
    cpu)    printf 'cpu' ;;
  esac
}

# Try pulling a single tag. Shows pull progress so the user sees bytes
# moving. Non-fatal: returns 1 on any failure so the caller can
# continue down the chain. `set -e` does not abort inside an `if`
# condition, which is how we guard the pull without disabling -e.
try_pull_tag() {
  local tag="$1"
  # Defense in depth: refuse pre-release tags however the caller
  # obtained them. list_versioned_tags filters at enumeration; this
  # guard ensures a code path added later that hands a versioned tag
  # straight to the puller cannot bypass that filter.
  if printf '%s' "$tag" | grep -qE -- "$PRERELEASE_TAG_PATTERN"; then
    info "refusing pre-release tag $tag"
    return 1
  fi
  info "pulling $IMAGE:$tag"
  if docker pull "$IMAGE:$tag"; then
    return 0
  fi
  return 1
}

# List versioned tags for a tag suffix (e.g. "cpu" or "cpu-arm64"),
# newest first. Uses the Docker Hub Hub API for public repositories —
# unauthenticated, no token trade required. Returns empty on any
# registry or parse error so the caller can treat it as "no older
# versions" rather than aborting; a flaky network at list time still
# lets stage-1 floating tags succeed.
list_versioned_tags() {
  local suffix="$1"
  local tags_json
  tags_json="$(curl -fsSL --max-time 10 \
    "https://hub.docker.com/v2/repositories/$DOCKERHUB_REPO/tags/?page_size=100" \
    2>/dev/null)"
  [ -z "$tags_json" ] && return 0
  # Filter out pre-release tags so a versioned pre-release that leaked
  # into Docker Hub cannot be promoted to a fresh customer via sort -rV.
  # sort -V does not implement semver pre-release ordering - it would
  # rank v1.4.5-rc1 above v1.4.4. See PRERELEASE_TAG_PATTERN at the
  # top of this file for the canonical pattern.
  #
  # Docker Hub encodes tag names as "name":"<tag>". Anchoring on `"name":"`
  # keeps the parse robust against the rest of each tag record
  # (architectures, digests, last_updated, ...).
  printf '%s' "$tags_json" \
    | tr ',' '\n' \
    | sed -n 's/.*"name":"\(v[0-9][^"]*-'"$suffix"'\)".*/\1/p' \
    | grep -vE -- "$PRERELEASE_TAG_PATTERN" \
    | sort -rV
}

# Walks the fallback chain for $BACKEND. Stage 1 tries floating
# per-backend tags (multi-arch manifest lists); stage 2 enumerates
# versioned stable tags for the same backends if no floating tag
# resolves. On success sets RESOLVED_TAG and (on a backend downgrade)
# mutates BACKEND so the device-flag switch in step 7 stays consistent
# with what was actually pulled. On total miss leaves RESOLVED_TAG
# empty and returns 1.
#
# The suffix parameter is retained for forward compatibility but is
# currently always empty - multi-arch manifests make per-arch suffixes
# unnecessary.
resolve_with_suffix() {
  local suffix="$1"
  local candidate vtag tag
  for candidate in $(backend_chain "$BACKEND"); do
    tag="${candidate}${suffix}"
    if try_pull_tag "$tag"; then
      if [ "$candidate" != "$BACKEND" ]; then
        warn "'$BACKEND' image unavailable - falling back to '$candidate'"
        BACKEND="$candidate"
      fi
      RESOLVED_TAG="$tag"
      return 0
    fi
  done
  # Stage 2: no floating tag resolved. Enumerate versioned tags
  # (newest stable first, pre-releases filtered) and pull the first
  # that exists. This covers partial-release windows or registry
  # flakiness at list time.
  info "no floating tag${suffix:+ (suffix $suffix)} - checking versioned tags"
  for candidate in $(backend_chain "$BACKEND"); do
    for vtag in $(list_versioned_tags "${candidate}${suffix}"); do
      if try_pull_tag "$vtag"; then
        if [ "$candidate" != "$BACKEND" ]; then
          warn "'$BACKEND' image unavailable - falling back to '$candidate' at $vtag"
          BACKEND="$candidate"
        fi
        RESOLVED_TAG="$vtag"
        return 0
      fi
    done
  done
  return 1
}

# -- License file reader ----------------------------------------------
# Extract a license key from a file. JSON files (".json" suffix) are
# parsed for a `.key` or `.license_key` field; everything else is
# treated as plain text - first non-empty trimmed line is the key.
#
# Result is written directly into NEOHIVE_LICENSE_KEY rather than stdout.
# This avoids running `fail` inside a `$(...)` command substitution, where
# `exit 1` only kills the subshell - the parent assignment would get an
# empty value and the installer would continue with a blank key.
# `inherit_errexit` is not on (and cannot be flipped safely - other call
# sites like list_versioned_tags rely on empty-on-failure $() behaviour),
# so writing to a shared variable in the parent shell is the safe fix.
read_license_file() {
  local path="$1" raw key=""
  NEOHIVE_LICENSE_KEY=""
  [ -r "$path" ] || fail E304 "License file '$path' is not readable."
  raw="$(cat "$path")"
  [ -n "$raw" ] || fail E305 "License file '$path' is empty."
  case "$path" in
    *.json)
      if command -v jq >/dev/null 2>&1; then
        key="$(printf '%s' "$raw" | jq -r '.key // .license_key // empty' 2>/dev/null || true)"
      fi
      if [ -z "$key" ]; then
        key="$(printf '%s' "$raw" | grep -oE '"(license_)?key"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
      fi
      [ -n "$key" ] || fail E306 "License file '$path' is JSON but no .key field found."
      ;;
    *)
      key="$(printf '%s' "$raw" | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | head -n1)"
      ;;
  esac
  [ -n "$key" ] || fail E307 "Could not extract license key from '$path'."
  NEOHIVE_LICENSE_KEY="$key"
  export NEOHIVE_LICENSE_KEY
}

# Resolve a license file path then export NEOHIVE_LICENSE_KEY from it
# so resolve_license picks it up via the env-var branch. Skipped if
# NEOHIVE_LICENSE_KEY is already set (env always wins) or if the user
# asked for rotation (NEOHIVE_ROTATE_LICENSE=1).
#
# Arg $1: explicit path from CLI flag (may be empty).
#
# Resolution order: $1 > NEOHIVE_LICENSE_FILE > auto-detect license.json
# / license.key in CWD then the installer's script dir.
apply_license_file() {
  local cli_path="${1:-}" resolved="" candidate
  [ -n "${NEOHIVE_LICENSE_KEY:-}" ] && return 0
  [ "${NEOHIVE_ROTATE_LICENSE:-0}" = "1" ] && return 0
  if [ -n "$cli_path" ]; then
    [ -f "$cli_path" ] || fail E308 "--license-file '$cli_path' does not exist."
    resolved="$cli_path"
  elif [ -n "${NEOHIVE_LICENSE_FILE:-}" ]; then
    [ -f "$NEOHIVE_LICENSE_FILE" ] || fail E309 "NEOHIVE_LICENSE_FILE '$NEOHIVE_LICENSE_FILE' does not exist."
    resolved="$NEOHIVE_LICENSE_FILE"
  else
    for candidate in \
      "$PWD/license.json" "$PWD/license.key" \
      "$SCRIPT_DIR/license.json" "$SCRIPT_DIR/license.key"; do
      if [ -f "$candidate" ]; then
        resolved="$candidate"
        break
      fi
    done
  fi
  if [ -n "$resolved" ]; then
    # Call without command substitution so `fail` inside read_license_file
    # exits the installer instead of the subshell. The function writes
    # NEOHIVE_LICENSE_KEY directly. See note on read_license_file.
    read_license_file "$resolved"
    info "Loaded license key from $resolved" >&2
  fi
}

# -- License resolver -------------------------------------------------
# Defined above the library-mode guard so install-dev.sh (which sources
# this file with NEOHIVE_LIB_ONLY=1) can call it directly. Priority:
# NEOHIVE_LICENSE_KEY env > cache (unless NEOHIVE_ROTATE_LICENSE=1) > TTY prompt
# for a file path.
#
# `apply_license_file` runs earlier in the main flow and writes
# NEOHIVE_LICENSE_KEY out of any of {--license-file, NEOHIVE_LICENSE_FILE,
# auto-detected license.json/license.key in CWD or script dir}. By the
# time this function is called the env-var branch has already absorbed
# all the file-resolution paths, so we only handle the env var, the
# cache, and the interactive fallback.
#
# stdout is the license key. All status lines go to stderr to avoid
# corrupting the value passed downstream to curl / docker run.
resolve_license() {
  local src_path key
  if [ -n "${NEOHIVE_LICENSE_KEY:-}" ]; then
    info "Using license key from NEOHIVE_LICENSE_KEY env var" >&2
    key="$NEOHIVE_LICENSE_KEY"
  elif [ "${NEOHIVE_ROTATE_LICENSE:-0}" != "1" ] && [ -s "$LICENSE_CACHE_FILE" ]; then
    info "Using cached license key at $LICENSE_CACHE_FILE" >&2
    cat "$LICENSE_CACHE_FILE"
    return
  else
    if [ ! -t 0 ]; then
      fail E301 "No license. Set NEOHIVE_LICENSE_FILE (or pass --license-file), or drop a license.key / license.json next to install.sh, or run interactively. Contact hello@neohive.ai for your license."
    fi
    printf '      %sPath to your NeoHive license file:%s ' "$C_BOLD" "$C_RESET" >&2
    read -r src_path
    # Expand a leading ~ and ~user against the shell's tilde rules so a
    # pasted "~/Downloads/neohive.license" Just Works in interactive mode.
    case "$src_path" in
      "~"|"~/"*) src_path="${HOME}${src_path#\~}" ;;
    esac
    if [ -z "$src_path" ]; then
      fail E302 "Empty path."
    fi
    if [ ! -f "$src_path" ] || [ ! -r "$src_path" ]; then
      fail E301 "$src_path is not a readable file. Verify the path and re-run."
    fi
    # Delegate parsing to read_license_file so .json files get the same
    # jq/grep extraction the non-interactive paths use. It writes the
    # extracted value into NEOHIVE_LICENSE_KEY.
    read_license_file "$src_path"
    key="$NEOHIVE_LICENSE_KEY"
    info "Read license key from $src_path" >&2
  fi

  # Cache the extracted key contents so upgrades / restarts don't need
  # the original file path again. The cache is what subsequent installs
  # read from when neither env var nor rotation is set.
  if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    warn "Cannot create $CACHE_DIR - license key will not be persisted"
  else
    chmod 700 "$CACHE_DIR" 2>/dev/null || true
    if printf '%s' "$key" > "$LICENSE_CACHE_FILE" 2>/dev/null; then
      chmod 600 "$LICENSE_CACHE_FILE" 2>/dev/null || true
      info "License key cached to $LICENSE_CACHE_FILE" >&2
    else
      warn "Cannot write $LICENSE_CACHE_FILE - license key will not be persisted"
    fi
  fi
  printf '%s' "$key"
}

# Resolve the fingerprint the gateway will use at boot. The gateway reads
# `${MEMVEC_DATA_DIR}/machine-id` (a persisted UUID) before falling back to
# `/etc/machine-id` and hostname. To keep the preflight and the running
# container in lockstep we own the UUID host-side and bind-mount it at
# `/app/data/machine-id`. That makes seat allocation idempotent across
# reinstalls regardless of whether the data volume already has a file, and
# avoids the silent-failure mode where an alpine helper exec fails (Docker
# Hub rate-limit, sandbox, daemon quirks) and the preflight ends up sending
# `hostname:/etc/machine-id` while the container sends just the contents of
# `/etc/machine-id` (mismatched fingerprints, NO_MACHINES on every preflight).
#
# Resolution order:
#   1. Host cache `$CACHE_DIR/machine-id` (most stable across reinstalls).
#   2. Existing volume `/app/data/machine-id` (older installs may have one
#      written by the runtime gateway; reuse so we don't churn the seat).
#   3. Fresh UUID generated host-side.
#
# In all paths the resolved UUID is mirrored to `$CACHE_DIR/machine-id` so
# subsequent installs short-circuit at step 1. The bind-mount at step 9 then
# overlays this file at /app/data/machine-id so the gateway reads the same
# UUID the preflight just used.
FP_RESOLVED=""
FP_CACHE_FILE="$CACHE_DIR/machine-id"
resolve_container_fingerprint() {
  if [ -n "$FP_RESOLVED" ]; then
    printf "%s" "$FP_RESOLVED"
    return 0
  fi

  local fp=""

  # 1. Host cache wins.
  if [ -s "$FP_CACHE_FILE" ]; then
    fp="$(tr -d '\n\r ' < "$FP_CACHE_FILE" 2>/dev/null || true)"
  fi

  # 2. Read from existing volume (legacy installs).
  if [ -z "$fp" ]; then
    docker volume create "$VOLUME_NAME" >/dev/null 2>&1 || true
    local helper_image="alpine:3"
    if ! docker image inspect "$helper_image" >/dev/null 2>&1; then
      if docker image inspect busybox >/dev/null 2>&1; then
        helper_image="busybox"
      fi
    fi
    fp="$(docker run --rm -v "$VOLUME_NAME:/app/data" "$helper_image" sh -c '
      if [ -s /app/data/machine-id ]; then
        cat /app/data/machine-id
      fi
    ' 2>/dev/null | tr -d '\n\r ' || true)"
  fi

  # 3. Generate a fresh UUID host-side.
  if [ -z "$fp" ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
      fp="$(tr -d '\n\r ' < /proc/sys/kernel/random/uuid 2>/dev/null || true)"
    fi
    if [ -z "$fp" ] && command -v uuidgen >/dev/null 2>&1; then
      fp="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '\n\r ' || true)"
    fi
    if [ -z "$fp" ] && command -v python3 >/dev/null 2>&1; then
      fp="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null | tr -d '\n\r ' || true)"
    fi
  fi

  if [ -z "$fp" ]; then
    fail E601 "Could not derive a machine fingerprint (no /proc/sys/kernel/random/uuid, uuidgen, or python3). Contact hello@neohive.ai."
  fi

  # Mirror to host cache so the next install short-circuits at step 1.
  if mkdir -p "$CACHE_DIR" 2>/dev/null; then
    chmod 700 "$CACHE_DIR" 2>/dev/null || true
    if [ ! -s "$FP_CACHE_FILE" ]; then
      if printf '%s' "$fp" > "$FP_CACHE_FILE" 2>/dev/null; then
        chmod 600 "$FP_CACHE_FILE" 2>/dev/null || true
      else
        warn "Could not persist fingerprint to $FP_CACHE_FILE - reinstalls may consume new Keygen seats"
      fi
    fi
  else
    warn "Could not create $CACHE_DIR - reinstalls may consume new Keygen seats"
  fi

  FP_RESOLVED="$fp"
  printf "%s" "$fp"
}

# Preflight: validate the license against api.keygen.sh before the
# 2GB pull. Tolerates network/5xx (offline grace will cover at boot).
# Hard-fails on 4xx and on 200-with-rejection-code so a bad key
# never gets cached or trusted by the runtime.
preflight_validate_license() {
  local fp resp body status detail

  if [ "$KEYGEN_ACCOUNT_ID" = "REPLACE_WITH_KEYGEN_ACCOUNT_UUID" ] || [ -z "$KEYGEN_ACCOUNT_ID" ]; then
    fail E101 "KEYGEN_ACCOUNT_ID not configured in install.sh (still placeholder). Contact hello@neohive.ai."
  fi

  fp="$(resolve_container_fingerprint)"

  # Single curl: capture body + status code together to avoid two Keygen
  # validation events per install.
  if ! resp="$(curl -sS --max-time 10 -w '\n__HTTP_STATUS__%{http_code}' \
        -X POST \
        -H 'Content-Type: application/vnd.api+json' \
        -H 'Accept: application/vnd.api+json' \
        -d "{\"meta\":{\"key\":\"$LICENSE_KEY\",\"scope\":{\"fingerprint\":\"$fp\",\"product\":\"$KEYGEN_PRODUCT_ID\"}}}" \
        "https://api.keygen.sh/v1/accounts/$KEYGEN_ACCOUNT_ID/licenses/actions/validate-key" \
        2>/dev/null)" || [ -z "$resp" ]; then
    warn "Could not reach api.keygen.sh (network/DNS) - proceeding (offline grace will apply at boot)"
    return 0
  fi

  status="${resp##*__HTTP_STATUS__}"
  body="${resp%__HTTP_STATUS__*}"
  # Drop the trailing newline that separated body from sentinel.
  body="${body%$'\n'}"

  if [ -z "$status" ] || [ "$status" = "000" ]; then
    warn "Could not reach api.keygen.sh (network/DNS) - proceeding (offline grace will apply at boot)"
    return 0
  fi

  if [ "$status" -ge 500 ] 2>/dev/null; then
    warn "api.keygen.sh returned HTTP $status - proceeding (offline grace will apply at boot)"
    return 0
  fi

  if [ "$status" -ge 400 ] && [ "$status" -lt 500 ] 2>/dev/null; then
    detail=$(echo "$body" | grep -oE '"detail":"[^"]*"' | head -n1 | cut -d'"' -f4)
    rm -f "$LICENSE_CACHE_FILE"
    warn "License rejected by Keygen (HTTP $status): ${detail:-unknown}"
    return 1
  fi

  if echo "$body" | grep -qE '"code":"VALID"'; then
    detail=$(echo "$body" | grep -oE '"detail":"[^"]*"' | head -n1 | cut -d'"' -f4)
    ok "${detail:-license accepted}"
    return 0
  fi
  # NO_MACHINES / FINGERPRINT_SCOPE_MISMATCH: the license is valid but this
  # fingerprint is not yet activated. The container's runtime activation will
  # register the seat on first boot. Keygen's "detail" wording for these
  # codes ("is not activated", "has no associated machines") reads as a
  # warning to operators, so substitute a clearer message.
  if echo "$body" | grep -qE '"code":"(NO_MACHINE|NO_MACHINES|FINGERPRINT_SCOPE_MISMATCH)"'; then
    ok "license valid (this machine will be registered on first start)"
    return 0
  fi

  detail=$(echo "$body" | grep -oE '"detail":"[^"]*"' | head -n1 | cut -d'"' -f4)
  rm -f "$LICENSE_CACHE_FILE"
  warn "License rejected by Keygen: ${detail:-unknown}"
  return 1
}

# Wrap resolve_license + preflight in a retry loop. On rejection we
# clear the cache (preflight already did) and re-prompt the user with
# NEOHIVE_ROTATE_LICENSE=1 set so resolve_license skips any stale env
# value path that points back at the bad key. Non-TTY runs cannot
# re-prompt so we give up after the first failure - same behaviour
# as a missing key.
license_resolve_and_validate() {
  local max_attempts=3 attempt=1
  while [ $attempt -le $max_attempts ]; do
    LICENSE_KEY="$(resolve_license)"
    if preflight_validate_license; then
      return 0
    fi
    if [ ! -t 0 ]; then
      fail E303 "License rejected and stdin is not a TTY - cannot re-prompt. Point NEOHIVE_LICENSE_FILE at a valid license file and retry."
    fi
    if [ $attempt -ge $max_attempts ]; then
      fail E304 "License rejected after $max_attempts attempts. Contact hello@neohive.ai."
    fi
    warn "Attempt $attempt of $max_attempts failed - re-prompting for license file path"
    # Force a fresh prompt: cache was rm'd in preflight, but a stale
    # NEOHIVE_LICENSE_KEY / NEOHIVE_LICENSE_FILE env var would short-circuit
    # back to the bad value. Unset both for retries.
    unset NEOHIVE_LICENSE_KEY NEOHIVE_LICENSE_FILE
    export NEOHIVE_ROTATE_LICENSE=1
    attempt=$((attempt + 1))
  done
  return 1
}

# ----------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------
# Library mode: when sourced with NEOHIVE_LIB_ONLY=1 (by the dry-run
# harness, for instance), stop here so only the helpers above are
# loaded. Guarded on BASH_SOURCE vs $0 so that directly executing the
# script never triggers the early return.
if [ "${BASH_SOURCE[0]}" != "${0}" ] && [ "${NEOHIVE_LIB_ONLY:-0}" = "1" ]; then
  return 0
fi

print_banner

# Parse --license-file / -l flag. Anything else is left for future args
# or silently dropped (the installer takes no other CLI flags today).
CLI_LICENSE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --license-file=*) CLI_LICENSE_FILE="${1#*=}"; shift ;;
    --license-file|-l)
      [ $# -lt 2 ] && fail E303 "$1 requires a path argument."
      CLI_LICENSE_FILE="$2"; shift 2 ;;
    --) shift; break ;;
    -*) fail E303 "Unknown argument: $1" ;;
    *) shift ;;
  esac
done
apply_license_file "$CLI_LICENSE_FILE"

# [1] Platform
# NeoHive images are published as multi-arch manifest lists - `:cpu`,
# `:latest`, and `:v<version>` carry both linux/amd64 and linux/arm64
# layers, and `docker pull` selects the matching layer automatically.
# The installer does not append an arch suffix to tags; the manifest
# list handles arch selection.
step 1 "Detecting platform..."
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
case "$UNAME_S" in
  Linux)  info "Linux $UNAME_M" ;;
  Darwin) info "macOS $UNAME_M" ;;
  *) fail E201 "Unsupported OS: $UNAME_S. Linux and macOS are supported. On Windows, install via WSL2." ;;
esac
ok

# [2] Docker
step 2 "Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  fail E202 "Docker is not installed. Install from https://docs.docker.com/get-docker/ and retry."
fi
if ! docker info >/dev/null 2>&1; then
  fail E203 "Docker daemon is not running (or current user cannot access it). Start Docker and retry."
fi
DOCKER_VERSION="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true)"
info "Docker ${DOCKER_VERSION:-(unknown version)} - daemon reachable"
ok

# [3] License resolution
# Priority: NEOHIVE_LICENSE_FILE env > cache (unless rotate set) > TTY prompt.
# Non-TTY without the env var fails fast - the container refuses to boot
# without a key, so failing here saves the customer a 2GB pull.
step 3 "Reading license file..."
LICENSE_KEY="$(resolve_license)"
ok

# [4] Pre-flight license validation
# Catches bad/expired keys before the 2GB pull. Tolerates network
# failure (firewall, no DNS) - the container has a 72h offline grace
# at boot, so an unreachable api.keygen.sh should not block install.
# Acceptable codes: VALID (already activated for this fingerprint),
# NO_MACHINES (first install - gateway will activate at boot), and
# FINGERPRINT_SCOPE_MISMATCH (same: gateway will activate).
# On 4xx rejection: re-prompt up to 3 times (TTY only) so a typo'd
# path or rotated key does not force the user to restart the installer.
step 4 "Validating license..."
if ! preflight_validate_license; then
  license_resolve_and_validate
fi

# [5] Backend detect
# On arm64 we skip GPU autodetection entirely: the release pipeline only
# builds cpu for arm64 (cuda/rocm need NVIDIA/AMD data-centre silicon,
# vulkan is irrelevant on Mac). A forced NEOHIVE_BACKEND still wins - if
# the user knows they have a Jetson or similar, let them try, and the
# pull stage will fail loudly if no matching image exists.
step 5 "Detecting hardware backend..."
if [ -n "${NEOHIVE_BACKEND:-}" ]; then
  BACKEND="$NEOHIVE_BACKEND"
  FORCED=1
elif [ "$UNAME_M" = "arm64" ] || [ "$UNAME_M" = "aarch64" ]; then
  BACKEND=cpu
  FORCED=0
  info "arm64 host - using CPU backend (Apple Silicon optimized)"
elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  info "NVIDIA GPU detected - probing container runtime..."
  # nvidia-smi on the host is not enough. The :cuda image ships no CUDA
  # libs of its own - it depends on NVIDIA Container Toolkit to bind-mount
  # libcuda.so and the CUDA runtime at container start (via --gpus all).
  # On WSL2 / Docker Desktop the Windows driver exposes nvidia-smi through
  # passthrough, but the container toolkit is a separate install that is
  # easy to miss. Without it, --gpus all "succeeds" but libcuda.so never
  # reaches the container, and the Rust embedder dies on LlamaBackend::init.
  # Probe with a tiny CUDA base image that is cheap to pull; fall back to
  # cpu on failure so the user gets a working install instead of a broken
  # cuda daemon.
  if docker run --rm --gpus all \
       nvidia/cuda:12.2.2-base-ubuntu22.04 nvidia-smi -L \
       >/dev/null 2>&1; then
    BACKEND=cuda
    FORCED=0
    info "NVIDIA Container Toolkit working - using CUDA backend"
  else
    BACKEND=cpu
    FORCED=0
    warn "NVIDIA Container Toolkit probe failed - falling back to CPU backend."
    warn "To enable CUDA: install nvidia-container-toolkit and restart Docker,"
    warn "then re-run this installer or set NEOHIVE_BACKEND=cuda to force."
  fi
elif command -v rocm-smi >/dev/null 2>&1 && rocm-smi >/dev/null 2>&1; then
  BACKEND=rocm
  FORCED=0
  info "AMD GPU (ROCm) detected"
elif command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary >/dev/null 2>&1; then
  BACKEND=vulkan
  FORCED=0
  info "Vulkan-capable GPU detected"
else
  BACKEND=cpu
  FORCED=0
  info "No GPU detected - using CPU"
fi
case "$BACKEND" in
  cpu|vulkan|cuda|rocm) ;;
  *) fail E204 "Invalid BACKEND '$BACKEND' (expected cpu|vulkan|cuda|rocm)" ;;
esac
if [ "$FORCED" -eq 1 ]; then
  info "Backend forced via NEOHIVE_BACKEND"
fi
ok "using '$BACKEND' backend"

# [6] Pull
# Resolution order:
#   1. Floating per-backend tag (:cpu, :cuda, :vulkan, :rocm) via the
#      fallback chain in resolve_with_suffix - each is a multi-arch
#      manifest list, so docker pull picks the right arch layer.
#   2. If no floating tag resolves (partial release, floating tag
#      missing for the detected backend, etc.), enumerate versioned
#      tags (v<X.Y.Z>-<backend>) and pull the newest stable. Pre-release
#      tags are filtered out in list_versioned_tags so internal RCs
#      cannot reach fresh customers.
# A forced backend (NEOHIVE_BACKEND set) skips fallback entirely and
# fails on a single missed pull, so the override is never silently
# downgraded.
step 6 "Pulling container image..."
RESOLVED_TAG=""
if [ "$FORCED" -eq 1 ]; then
  if try_pull_tag "$BACKEND"; then
    RESOLVED_TAG="$BACKEND"
  else
    fail E501 "image '$IMAGE:$BACKEND' not found and NEOHIVE_BACKEND is set - unset it to allow automatic fallback."
  fi
else
  resolve_with_suffix "" || true
fi
if [ -z "$RESOLVED_TAG" ]; then
  fail E502 "no compatible image found on $IMAGE. Check connectivity to Docker Hub and retry."
fi
ok "image ready ($RESOLVED_TAG)"

# [7] Run
# Detect upgrade vs fresh install BEFORE we tear down the existing
# container. Presence of the data volume is the durable signal - the
# container may have been `docker rm`'d but a returning user's data
# survives in the volume, and we still want to greet them with release
# notes rather than the "create your first project" walkthrough.
IS_UPDATE=0
if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
  IS_UPDATE=1
fi
step 7 "Starting NeoHive server..."
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  info "Stopping existing container for upgrade..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi
RUN_ARGS=(
  -d
  --name "$CONTAINER_NAME"
  --restart on-failure:3
  -v "$VOLUME_NAME:/app/data"
  -p "$PORT:3577"
  -e NEOHIVE_LICENSE_KEY="$LICENSE_KEY"
  # The in-app update checker queries the public Docker Hub Hub API for
  # new tags, so no registry credentials are forwarded into the container.
  # Keygen account ID, product ID, API URL, and grace-hours are also
  # intentionally NOT forwarded as env vars - they are baked into the
  # image so they cannot be overridden at runtime.
)

# Fingerprint must be stable across container recreations or every restart
# burns a Keygen seat. We bind-mount the host-cached UUID into the data dir
# so the gateway reads it via `${MEMVEC_DATA_DIR}/machine-id` regardless of
# what the volume contains, and the preflight UUID matches the runtime UUID.
resolve_container_fingerprint >/dev/null
if [ -s "$FP_CACHE_FILE" ]; then
  RUN_ARGS+=(-v "$FP_CACHE_FILE:/app/data/machine-id:ro")
else
  fail E601 "Fingerprint cache $FP_CACHE_FILE is missing. Restarting this container would consume a new Keygen seat each time. Contact hello@neohive.ai."
fi
if [ -n "${NEOHIVE_UPDATE_REPO:-}" ]; then
  RUN_ARGS+=(-e "NEOHIVE_UPDATE_REPO=$NEOHIVE_UPDATE_REPO")
fi
# Optional timeout overrides. All three are validated as positive integers
# (milliseconds) and forwarded under the backend's internal MEMVEC_* names
# so users only have to learn the NEOHIVE_-prefixed knobs. The PDF bridge
# timeout is the one customers ingesting large PDFs need - a 900-page
# document hits the 300s default well before docling finishes.
forward_timeout_env() {
  local user_var="$1"  # NEOHIVE_*
  local container_var="$2"  # MEMVEC_*
  local value="${!user_var:-}"
  [ -z "$value" ] && return 0
  if ! printf '%s' "$value" | grep -qE '^[1-9][0-9]*$'; then
    fail E603 "$user_var must be a positive integer (milliseconds). Got: '$value'"
  fi
  info "${container_var} override: ${value}ms"
  RUN_ARGS+=(-e "${container_var}=${value}")
}
forward_timeout_env NEOHIVE_PDF_BRIDGE_TIMEOUT_MS MEMVEC_PDF_BRIDGE_TIMEOUT_MS
forward_timeout_env NEOHIVE_PDF_WARMUP_TIMEOUT_MS MEMVEC_PDF_WARMUP_TIMEOUT_MS
forward_timeout_env NEOHIVE_CHUNKER_TIMEOUT_MS    MEMVEC_CHUNKER_TIMEOUT_MS
case "$BACKEND" in
  vulkan) RUN_ARGS+=(--device /dev/dri) ;;
  cuda)   RUN_ARGS+=(--gpus all) ;;
  rocm)   RUN_ARGS+=(--device /dev/kfd --device /dev/dri --group-add video --group-add render) ;;
esac
docker run "${RUN_ARGS[@]}" "$IMAGE:$RESOLVED_TAG" >/dev/null
info "Container started on port $PORT"
info "Waiting for /health (up to ${HEALTH_TIMEOUT_SECONDS}s)..."
START=$(date +%s)
HEALTHY=0
DEADLINE=$(( START + HEALTH_TIMEOUT_SECONDS ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 2
done
if [ $HEALTHY -eq 0 ]; then
  printf '\n      Last 50 log lines from the container:\n' >&2
  docker logs "$CONTAINER_NAME" 2>&1 | tail -50 >&2
  fail E602 "/health did not respond in ${HEALTH_TIMEOUT_SECONDS}s. Inspect: docker logs $CONTAINER_NAME"
fi
ELAPSED=$(( $(date +%s) - START ))
ok "ready in ${ELAPSED}s"

# Query the gateway's /api/license/status once it is up. Best-effort:
# if the endpoint cannot be reached or fields are missing, just skip
# the line - the install itself already succeeded.
print_license_summary() {
  local status mode expires holder days grace_remaining grace_total attempts=0
  while [ $attempts -lt 15 ]; do
    if status="$(curl -sSf -m 2 "http://localhost:$PORT/api/license/status" 2>/dev/null)"; then
      mode=$(echo "$status" | grep -oE '"status":"[^"]+"' | head -n1 | cut -d'"' -f4)
      expires=$(echo "$status" | grep -oE '"expiresAt":"[^"]+"' | head -n1 | cut -d'"' -f4)
      holder=$(echo "$status" | grep -oE '"holderName":"[^"]+"' | head -n1 | cut -d'"' -f4)
      days=$(echo "$status" | grep -oE '"daysRemaining":-?[0-9]+' | head -n1 | cut -d':' -f2)
      grace_remaining=$(echo "$status" | grep -oE '"graceHoursRemaining":-?[0-9]+(\.[0-9]+)?' | head -n1 | cut -d':' -f2)
      grace_total=$(echo "$status" | grep -oE '"graceHoursTotal":[0-9]+' | head -n1 | cut -d':' -f2)
      printf '      License: %s' "${mode:-unknown}"
      [ -n "$expires" ] && printf ' (expires %s, %s days)' "$expires" "$days"
      [ -n "$holder" ] && printf ' - %s' "$holder"
      printf '\n'
      if [ "$mode" = "grace" ]; then
        print_grace_banner "${grace_remaining:-?}" "${grace_total:-?}"
      fi
      return
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  warn "Could not query license status from server"
}

# Loud banner shown only when the gateway came up in offline-grace mode -
# preflight passed (or was tolerated) but the runtime activation call to
# api.keygen.sh failed, so the container is serving on cached state.
# Operator-facing: business users see the dashboard banner / bottom-right
# notification, but the person running the installer needs to know now.
print_grace_banner() {
  local remaining="$1" total="$2"
  local bar
  bar=$(printf '%*s' 67 '' | tr ' ' '=')
  printf '\n   %s%s%s%s\n' "$C_BOLD" "$C_RED" "$bar" "$C_RESET"
  printf '   %s%s  ! OFFLINE GRACE MODE  !%s\n' "$C_BOLD" "$C_RED" "$C_RESET"
  printf '   %s%s%s\n' "$C_RED" "$bar" "$C_RESET"
  printf '   Could not reach and validate with licensing during activation.\n'
  printf '   Running on cached license state. %s%s~%sh of %sh remaining%s\n' \
    "$C_BOLD" "$C_RED" "${remaining}" "${total}" "$C_RESET"
  printf '   before the server stops serving requests.\n\n'
  printf '     - check internet access, firewall, or proxy settings\n'
  printf '     - if connectivity looks fine, %sverify your license has\n' "$C_BOLD"
  printf '       not expired%s\n' "$C_RESET"
  printf '   %s%s%s\n\n' "$C_RED" "$bar" "$C_RESET"
}
print_license_summary

if [ "$IS_UPDATE" -eq 1 ]; then
  print_post_install_update
else
  print_post_install
fi
