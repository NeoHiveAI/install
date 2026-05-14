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
#   NEOHIVE_PAT                - GHCR token; required when stdin is not a TTY
#   NEOHIVE_ROTATE_PAT         - set to 1 to force re-prompt even if cached PAT exists
#   NEOHIVE_LICENSE_KEY        - Keygen license key; required when stdin is not a TTY
#   NEOHIVE_ROTATE_LICENSE     - set to 1 to force re-read of license (skip cache)
#   NEOHIVE_UPDATE_REPO        - override the GHCR repo for in-app update checks
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
# The PAT is cached at $XDG_CACHE_HOME/neohive/ghcr-pat (or ~/.cache/neohive/
# if XDG is unset) with mode 0600 so the customer does not re-paste on
# upgrade. The license key is cached at $CACHE_DIR/license-key, same mode.
# Re-running the script is the supported upgrade path.
#
# The server serves plain HTTP on a single port. Customers who need TLS
# wrap their MCP endpoint with the mcp-remote npm package on the client
# side - no server-side TLS work.

set -euo pipefail

IMAGE="ghcr.io/neohiveai/neohive"
CONTAINER_NAME="neohive"
VOLUME_NAME="neohive-data"
DEFAULT_PORT=13577
HEALTH_TIMEOUT_SECONDS=60
TOTAL_STEPS=9
MAX_LOGIN_ATTEMPTS=3

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

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/neohive"
PAT_FILE="$CACHE_DIR/ghcr-pat"
LICENSE_FILE="$CACHE_DIR/license-key"
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
# step()  - "[N/7] Message..."
# info()  - indented informational line
# ok()    - indented OK marker, optional trailing detail
# warn()  - indented WARN marker (stderr)
# fail()  - indented FAIL marker (stderr), exits 1
step() {
  printf '%s[%d/%d]%s %s\n' "$C_CYAN" "$1" "$TOTAL_STEPS" "$C_RESET" "$2"
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
fail() { printf '      %sFAIL%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

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
  printf '     Upgrade:        re-run this installer (cached token is reused).\n'
  printf '     Rotate token:   %sNEOHIVE_ROTATE_PAT=1 bash <(curl ...)%s\n' "$C_DIM" "$C_RESET"
  printf '     Rotate license: %sNEOHIVE_ROTATE_LICENSE=1 NEOHIVE_LICENSE_KEY=<new-key> bash <(curl ...)%s\n' "$C_DIM" "$C_RESET"
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
  printf '     Rotate token:   %sNEOHIVE_ROTATE_PAT=1 bash <(curl ...)%s\n' "$C_DIM" "$C_RESET"
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
# newest first. Uses the Docker Registry v2 API on GHCR: first trade
# the PAT for a short-lived bearer at /token, then list tags. Returns
# empty on any registry or parse error - the caller treats that as
# "no older versions" rather than aborting, so a flaky network at
# list time still lets stage-1 floating tags succeed.
list_versioned_tags() {
  local suffix="$1"
  local bearer tags_json
  bearer="$(curl -fsSL \
    -u "neohive-service:$PAT" \
    "https://ghcr.io/token?scope=repository:neohiveai/neohive:pull" \
    2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  [ -z "$bearer" ] && return 0
  tags_json="$(curl -fsSL \
    -H "Authorization: Bearer $bearer" \
    "https://ghcr.io/v2/neohiveai/neohive/tags/list" 2>/dev/null)"
  [ -z "$tags_json" ] && return 0
  # Filter out pre-release tags so a versioned pre-release that leaked
  # into GHCR cannot be promoted to a fresh customer via sort -rV.
  # sort -V does not implement semver pre-release ordering - it would
  # rank v1.4.5-rc1 above v1.4.4. See PRERELEASE_TAG_PATTERN at the
  # top of this file for the canonical pattern.
  printf '%s' "$tags_json" \
    | tr ',' '\n' \
    | sed -n 's/.*"\(v[0-9][^"]*-'"$suffix"'\)".*/\1/p' \
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

# -- License resolver -------------------------------------------------
# Defined above the library-mode guard so install-dev.sh (which sources
# this file with NEOHIVE_LIB_ONLY=1) can call it directly. Priority:
# env > cache (unless NEOHIVE_ROTATE_LICENSE=1) > TTY prompt.
#
# stdout is the license key. All status lines go to stderr to avoid
# corrupting the value passed to curl.
resolve_license() {
  if [ -n "${NEOHIVE_LICENSE_KEY:-}" ]; then
    info "Using license key from NEOHIVE_LICENSE_KEY env var" >&2
    printf '%s' "$NEOHIVE_LICENSE_KEY"
    return
  fi
  if [ "${NEOHIVE_ROTATE_LICENSE:-0}" != "1" ] && [ -s "$LICENSE_FILE" ]; then
    info "Using cached license key at $LICENSE_FILE" >&2
    cat "$LICENSE_FILE"
    return
  fi
  if [ ! -t 0 ]; then
    fail "No license key. Set NEOHIVE_LICENSE_KEY or run interactively. Contact hello@neohive.ai for a key."
  fi
  printf '      %sPaste your NeoHive license key (input hidden):%s ' "$C_BOLD" "$C_RESET" >&2
  read -rs LICENSE_INPUT
  printf '\n' >&2
  if [ -z "$LICENSE_INPUT" ]; then
    fail "Empty license key."
  fi
  if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    warn "Cannot create $CACHE_DIR - license key will not be persisted"
  else
    chmod 700 "$CACHE_DIR"
    if printf '%s' "$LICENSE_INPUT" > "$LICENSE_FILE" 2>/dev/null; then
      chmod 600 "$LICENSE_FILE"
      info "License key cached to $LICENSE_FILE" >&2
    else
      warn "Cannot write $LICENSE_FILE - license key will not be persisted"
    fi
  fi
  printf '%s' "$LICENSE_INPUT"
}

# Resolve the fingerprint the gateway will use at boot. The gateway reads
# `${MEMVEC_DATA_DIR}/machine-id` (a persisted UUID) before falling back to
# `/etc/machine-id` and hostname. To avoid the preflight registering a
# different fingerprint than the running container (which would burn one
# failed Keygen validation + one wasted activation per first install),
# seed the same file into the data volume here and read it back.
resolve_container_fingerprint() {
  local fp
  # Ensure the named volume exists; harmless if already present.
  docker volume create "$VOLUME_NAME" >/dev/null 2>&1 || true
  # If the volume already has a machine-id (subsequent installs), reuse it.
  # Otherwise generate one and seed it now so the container reads the same
  # value on first boot. Use the smallest cached image we can find to avoid
  # pulling alpine just for this; busybox is also fine.
  local helper_image="alpine:3"
  if ! docker image inspect "$helper_image" >/dev/null 2>&1; then
    if docker image inspect busybox >/dev/null 2>&1; then
      helper_image="busybox"
    fi
  fi
  fp="$(docker run --rm -v "$VOLUME_NAME:/app/data" "$helper_image" sh -c '
    if [ -s /app/data/machine-id ]; then
      cat /app/data/machine-id
    else
      id="$(cat /proc/sys/kernel/random/uuid)"
      printf "%s" "$id" > /app/data/machine-id
      chmod 600 /app/data/machine-id 2>/dev/null || true
      printf "%s" "$id"
    fi
  ' 2>/dev/null | tr -d "\n\r ")"
  if [ -z "$fp" ]; then
    # Fallback: hostname+/etc/machine-id, matches the old behaviour.
    warn "Could not seed fingerprint into $VOLUME_NAME; falling back to host machine-id"
    fp="$(hostname):$(cat /etc/machine-id 2>/dev/null || echo unknown)"
  fi
  printf "%s" "$fp"
}

# Preflight: validate the license against api.keygen.sh before the
# 2GB pull. Tolerates network/5xx (offline grace will cover at boot).
# Hard-fails on 4xx and on 200-with-rejection-code so a bad key
# never gets cached or trusted by the runtime.
preflight_validate_license() {
  local fp resp body status detail

  if [ "$KEYGEN_ACCOUNT_ID" = "REPLACE_WITH_KEYGEN_ACCOUNT_UUID" ] || [ -z "$KEYGEN_ACCOUNT_ID" ]; then
    fail "KEYGEN_ACCOUNT_ID not configured in install.sh (still placeholder). Build/release bug - contact hello@neohive.ai."
  fi

  fp="$(resolve_container_fingerprint)"

  # Single curl: capture body + status code together to avoid two Keygen
  # validation events per install.
  resp="$(curl -sS --max-time 10 -w '\n__HTTP_STATUS__%{http_code}' \
        -X POST \
        -H 'Content-Type: application/vnd.api+json' \
        -H 'Accept: application/vnd.api+json' \
        -d "{\"meta\":{\"key\":\"$LICENSE_KEY\",\"scope\":{\"fingerprint\":\"$fp\",\"product\":\"$KEYGEN_PRODUCT_ID\"}}}" \
        "https://api.keygen.sh/v1/accounts/$KEYGEN_ACCOUNT_ID/licenses/actions/validate-key" \
        2>/dev/null)"
  if [ $? -ne 0 ] || [ -z "$resp" ]; then
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
    rm -f "$LICENSE_FILE"
    warn "License rejected by Keygen (HTTP $status): ${detail:-unknown}"
    return 1
  fi

  if echo "$body" | grep -qE '"code":"(VALID|NO_MACHINE|NO_MACHINES|FINGERPRINT_SCOPE_MISMATCH)"'; then
    detail=$(echo "$body" | grep -oE '"detail":"[^"]*"' | head -n1 | cut -d'"' -f4)
    ok "${detail:-license accepted}"
    return 0
  fi

  detail=$(echo "$body" | grep -oE '"detail":"[^"]*"' | head -n1 | cut -d'"' -f4)
  rm -f "$LICENSE_FILE"
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
      fail "License rejected and stdin is not a TTY - cannot re-prompt. Set NEOHIVE_LICENSE_KEY to a valid key and retry."
    fi
    if [ $attempt -ge $max_attempts ]; then
      fail "License rejected after $max_attempts attempts. Contact hello@neohive.ai."
    fi
    warn "Attempt $attempt of $max_attempts failed - re-prompting for license key"
    # Force a fresh prompt: cache was rm'd in preflight, but a stale
    # NEOHIVE_LICENSE_KEY env var would short-circuit resolve_license
    # straight back to the bad value. Unset it for retries.
    unset NEOHIVE_LICENSE_KEY
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

# [1/9] Platform
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
  *) fail "Unsupported OS: $UNAME_S. Linux and macOS are supported. On Windows, install via WSL2." ;;
esac
ok

# [2/9] Docker
step 2 "Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  fail "Docker is not installed. Install from https://docs.docker.com/get-docker/ and retry."
fi
if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon is not running (or current user cannot access it). Start Docker and retry."
fi
DOCKER_VERSION="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || true)"
info "Docker ${DOCKER_VERSION:-(unknown version)} - daemon reachable"
ok

# [3/9] License resolution
# Priority: env var > cache (unless rotate set) > interactive TTY prompt.
# Non-TTY without env var fails fast - the container refuses to boot
# without a key, so failing here saves the customer a 2GB pull.
step 3 "Resolving license key..."
LICENSE_KEY="$(resolve_license)"
ok

# [4/9] Pre-flight license validation
# Catches bad/expired keys before the 2GB pull. Tolerates network
# failure (firewall, no DNS) - the container has a 72h offline grace
# at boot, so an unreachable api.keygen.sh should not block install.
# Acceptable codes: VALID (already activated for this fingerprint),
# NO_MACHINES (first install - gateway will activate at boot), and
# FINGERPRINT_SCOPE_MISMATCH (same: gateway will activate).
# On 4xx rejection: re-prompt up to 3 times (TTY only) so a typo or a
# rotated key does not force the user to restart the installer.
step 4 "Validating license with Keygen..."
if ! preflight_validate_license; then
  license_resolve_and_validate
fi

# [5/9] Backend detect
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
  *) fail "Invalid BACKEND '$BACKEND' (expected cpu|vulkan|cuda|rocm)" ;;
esac
if [ "$FORCED" -eq 1 ]; then
  info "Backend forced via NEOHIVE_BACKEND"
fi
ok "using '$BACKEND' backend"

# [6/9] PAT resolution
step 6 "Resolving access token..."
resolve_pat() {
  # This function's STDOUT is the PAT. Status messages go to stderr
  # only - a stray newline on stdout corrupts the token and makes
  # docker login fail with a misleading error.
  if [ -n "${NEOHIVE_PAT:-}" ]; then
    info "Using token from NEOHIVE_PAT env var" >&2
    printf '%s' "$NEOHIVE_PAT"
    return
  fi
  if [ "${NEOHIVE_ROTATE_PAT:-}" != "1" ] && [ -s "$PAT_FILE" ]; then
    info "Using cached token at $PAT_FILE" >&2
    cat "$PAT_FILE"
    return
  fi
  if [ ! -t 0 ]; then
    fail "No PAT available. Set NEOHIVE_PAT=ghp_... or run interactively (stdin must be a TTY)."
  fi
  printf '      %sPaste your NeoHive GHCR access token (input hidden):%s ' "$C_BOLD" "$C_RESET" >&2
  read -rs PAT_INPUT
  printf '\n' >&2
  if [ -z "$PAT_INPUT" ]; then
    fail "Empty token."
  fi
  if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    warn "Cannot create $CACHE_DIR - token will not be persisted"
  else
    chmod 700 "$CACHE_DIR"
    if printf '%s' "$PAT_INPUT" > "$PAT_FILE" 2>/dev/null; then
      chmod 600 "$PAT_FILE"
      info "Token cached to $PAT_FILE" >&2
    else
      warn "Cannot write $PAT_FILE - token will not be persisted"
    fi
  fi
  printf '%s' "$PAT_INPUT"
}
PAT="$(resolve_pat)"
ok

# [7/9] Authenticate
# On rejection we clear the cached token and re-prompt up to
# MAX_LOGIN_ATTEMPTS times. If NEOHIVE_PAT was set explicitly we cannot
# re-prompt over an env-driven value, so we fail fast with the specific
# reason. Non-TTY runs likewise cannot recover - they must pass a valid
# NEOHIVE_PAT and retry.
step 7 "Authenticating to GHCR..."
LOGIN_ATTEMPT=0
while :; do
  LOGIN_ATTEMPT=$((LOGIN_ATTEMPT + 1))
  if printf '%s' "$PAT" | docker login ghcr.io -u neohive-service --password-stdin >/dev/null 2>&1; then
    break
  fi
  rm -f "$PAT_FILE"
  if [ -n "${NEOHIVE_PAT:-}" ]; then
    fail "docker login ghcr.io rejected the token from NEOHIVE_PAT. Check it has 'read:packages' scope on $IMAGE."
  fi
  if [ "$LOGIN_ATTEMPT" -ge "$MAX_LOGIN_ATTEMPTS" ]; then
    fail "docker login ghcr.io failed after $MAX_LOGIN_ATTEMPTS attempts. The token may be revoked or lack 'read:packages' scope on $IMAGE."
  fi
  if [ ! -t 0 ]; then
    fail "docker login ghcr.io failed and stdin is not a TTY (cannot re-prompt). Pass a valid NEOHIVE_PAT and retry."
  fi
  warn "GHCR rejected that token. Let's try a different one (attempt $((LOGIN_ATTEMPT + 1)) of $MAX_LOGIN_ATTEMPTS)."
  NEOHIVE_ROTATE_PAT=1
  PAT="$(resolve_pat)"
done
ok "ghcr.io/neohive-service"

# [8/9] Pull
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
step 8 "Pulling container image..."
RESOLVED_TAG=""
if [ "$FORCED" -eq 1 ]; then
  if try_pull_tag "$BACKEND"; then
    RESOLVED_TAG="$BACKEND"
  else
    fail "image '$IMAGE:$BACKEND' not found and NEOHIVE_BACKEND is set - unset it to allow automatic fallback."
  fi
else
  resolve_with_suffix "" || true
fi
if [ -z "$RESOLVED_TAG" ]; then
  fail "no compatible image found on $IMAGE. Check your PAT's repo access and retry."
fi
ok "image ready ($RESOLVED_TAG)"

# [9/9] Run
# Detect upgrade vs fresh install BEFORE we tear down the existing
# container. Presence of the data volume is the durable signal - the
# container may have been `docker rm`'d but a returning user's data
# survives in the volume, and we still want to greet them with release
# notes rather than the "create your first project" walkthrough.
IS_UPDATE=0
if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
  IS_UPDATE=1
fi
step 9 "Starting NeoHive server..."
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
  # Forward the GHCR PAT so the server's in-app update check can query
  # the same registry we just pulled from. Without this the banner stays
  # blank with "NEOHIVE_PAT not set". The host-side `docker login` only
  # authenticates the pull; the daemon does not pass that into the
  # container.
  -e "NEOHIVE_PAT=$PAT"
)
# Note: NEOHIVE_KEYGEN_ACCOUNT_ID, NEOHIVE_KEYGEN_PRODUCT_ID, KEYGEN
# API URL, and grace-hours are NOT passed through. They are baked into
# the image (cognitive-memory/src/gateway/license-config.ts) and the
# production build ignores env overrides for them on purpose - this
# is what stops a customer from redirecting validation to a fake
# Keygen tenant or extending the offline grace window arbitrarily.
# Bind-mount /etc/machine-id so the container fingerprint is stable
# across recreations. The volume-seeded /app/data/machine-id (written by
# resolve_container_fingerprint) is the primary source the gateway
# reads, but bind-mounting the host's id keeps the fallback path stable
# too. macOS Docker Desktop synthesizes its own machine-id inside the
# VM and the host file may be missing - warn and proceed in that case.
if [ -f /etc/machine-id ]; then
  RUN_ARGS+=(-v /etc/machine-id:/etc/machine-id:ro)
else
  warn "/etc/machine-id not found on host; container will use its own. Restarts may consume Keygen seats."
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
    fail "$user_var must be a positive integer (milliseconds). Got: '$value'"
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
  fail "/health did not respond in ${HEALTH_TIMEOUT_SECONDS}s. Inspect: docker logs $CONTAINER_NAME"
fi
ELAPSED=$(( $(date +%s) - START ))
ok "ready in ${ELAPSED}s"

# Query the gateway's /api/license/status once it is up. Best-effort:
# if the endpoint cannot be reached or fields are missing, just skip
# the line - the install itself already succeeded.
print_license_summary() {
  local status mode expires holder days attempts=0
  while [ $attempts -lt 15 ]; do
    if status="$(curl -sSf -m 2 "http://localhost:$PORT/api/license/status" 2>/dev/null)"; then
      mode=$(echo "$status" | grep -oE '"status":"[^"]+"' | head -n1 | cut -d'"' -f4)
      expires=$(echo "$status" | grep -oE '"expiresAt":"[^"]+"' | head -n1 | cut -d'"' -f4)
      holder=$(echo "$status" | grep -oE '"holderName":"[^"]+"' | head -n1 | cut -d'"' -f4)
      days=$(echo "$status" | grep -oE '"daysRemaining":-?[0-9]+' | head -n1 | cut -d':' -f2)
      printf '      License: %s' "${mode:-unknown}"
      [ -n "$expires" ] && printf ' (expires %s, %s days)' "$expires" "$days"
      [ -n "$holder" ] && printf ' - %s' "$holder"
      printf '\n'
      return
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  warn "Could not query license status from gateway"
}
print_license_summary

if [ "$IS_UPDATE" -eq 1 ]; then
  print_post_install_update
else
  print_post_install
fi
