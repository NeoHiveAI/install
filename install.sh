#!/usr/bin/env bash
#
# NeoHive installer.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh)
#
# Environment overrides (all optional):
#   NEOHIVE_BACKEND    - force backend: cpu|vulkan|cuda|rocm (default: autodetect)
#   NEOHIVE_PORT       - port to publish (default: 3577)
#   NEOHIVE_PAT        - GHCR token; required when stdin is not a TTY
#   NEOHIVE_ROTATE_PAT - set to 1 to force re-prompt even if cached PAT exists
#
# The PAT is cached at $XDG_CACHE_HOME/neohive/ghcr-pat (or ~/.cache/neohive/
# if XDG is unset) with mode 0600 so the customer does not re-paste on
# upgrade. Re-running the script is the supported upgrade path.
#
# The server serves plain HTTP on a single port. Customers who need TLS
# wrap their MCP endpoint with the mcp-remote npm package on the client
# side - no server-side TLS work.

set -euo pipefail

IMAGE="ghcr.io/neohiveai/neohive"
CONTAINER_NAME="neohive"
VOLUME_NAME="neohive-data"
DEFAULT_PORT=3577
HEALTH_TIMEOUT_SECONDS=60
TOTAL_STEPS=7

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/neohive"
PAT_FILE="$CACHE_DIR/ghcr-pat"
PORT="${NEOHIVE_PORT:-$DEFAULT_PORT}"

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
  printf '   %s%s%s\n\n' "$C_DIM" "$line" "$C_RESET"
}

# ----------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------
print_banner

# [1/7] Platform
step 1 "Detecting platform..."
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"
case "$UNAME_S" in
  Linux)  info "Linux $UNAME_M" ;;
  Darwin) info "macOS $UNAME_M" ;;
  *) fail "Unsupported OS: $UNAME_S. Linux and macOS are supported. On Windows, install via WSL2." ;;
esac
ok

# [2/7] Docker
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

# [3/7] Backend detect
step 3 "Detecting hardware backend..."
if [ -n "${NEOHIVE_BACKEND:-}" ]; then
  BACKEND="$NEOHIVE_BACKEND"
  FORCED=1
elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  BACKEND=cuda
  FORCED=0
  info "NVIDIA GPU detected"
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

# [4/7] PAT resolution
step 4 "Resolving access token..."
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

# [5/7] Authenticate
step 5 "Authenticating to GHCR..."
if ! printf '%s' "$PAT" | docker login ghcr.io -u neohive-service --password-stdin >/dev/null 2>&1; then
  rm -f "$PAT_FILE"
  fail "docker login ghcr.io failed. Your token may be revoked or expired. Re-run to enter a new one."
fi
ok "ghcr.io/neohive-service"

# [6/7] Pull
step 6 "Pulling container image..."
info "$IMAGE:$BACKEND"
docker pull "$IMAGE:$BACKEND"
ok "image ready"

# [7/7] Run
step 7 "Starting NeoHive server..."
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  info "Stopping existing container for upgrade..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi
RUN_ARGS=(
  -d
  --name "$CONTAINER_NAME"
  --restart unless-stopped
  -v "$VOLUME_NAME:/app/data"
  -p "$PORT:3577"
  -e NEOHIVE_LICENSE_ENABLED=false
)
case "$BACKEND" in
  vulkan) RUN_ARGS+=(--device /dev/dri) ;;
  cuda)   RUN_ARGS+=(--gpus all) ;;
  rocm)   RUN_ARGS+=(--device /dev/kfd --device /dev/dri --group-add video --group-add render) ;;
esac
docker run "${RUN_ARGS[@]}" "$IMAGE:$BACKEND" >/dev/null
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

print_post_install
