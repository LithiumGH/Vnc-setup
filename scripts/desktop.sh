#!/usr/bin/env bash
#
# Browser-based Ubuntu desktop for GitHub Actions (or any local Docker host).
#
# Streams an Ubuntu XFCE desktop to the browser using Selkies, which encodes
# H.264 with WebCodecs. That is dramatically lower latency than classic noVNC
# framebuffer streaming, which sends raw rectangles as PNG/JPEG.
#
# GitHub runners have no inbound ports, so the container is published through a
# Cloudflare Quick Tunnel: no account needed, and it hands back real HTTPS,
# which Selkies requires for WebCodecs to be available in the browser.
#
# Commands: up | tunnel | down | status | logs | shell | glinfo
#
set -Eeuo pipefail

# ---------------------------------------------------------------- config ----
IMAGE_REPO="${IMAGE_REPO:-lscr.io/linuxserver/webtop}"
FLAVOR="${FLAVOR:-ubuntu-xfce}"
CONTAINER="${CONTAINER:-ubuntu-desktop}"

VNC_USER="${VNC_USER:-dev}"
PASSWORD="${PASSWORD:-}"
TZ_NAME="${TZ:-Etc/UTC}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Latency knobs.
#
# SELKIES_BACKPRESSURE_QUEUE_SIZE is the big one: the upstream default of 120
# frames is ~2s of video buffered ahead of you at 60fps. Dropping it to 30 is
# what turns "usable" into "responsive", at the cost of a few dropped frames
# on a bad link. A 2.5ms Opus frame keeps audio latency low to match.
AUDIO_FRAME_MS="${AUDIO_FRAME_MS:-2.5}"
FRAMERATE="${FRAMERATE:-60}"
BACKPRESSURE="${BACKPRESSURE:-30}"

# Rendering.
#
# Neither GitHub runners nor Docker Desktop on WSL2 expose a GPU to the
# container (WSL2 only paravirtualises NVIDIA), so llvmpipe CPU rasterisation is
# the only realistic option. Verified in this image: Mesa 26 gives OpenGL 4.5
# core on llvmpipe/LLVM 21 with no extra packages.
#
# llvmpipe costs CPU proportional to pixels and frames, so resolution is pinned
# and the framerate is capped rather than left free. On a 2 vCPU runner that is
# the difference between a slideshow and something playable.
SOFTWARE_RENDER="${SOFTWARE_RENDER:-true}"
SOFTWARE_WIDTH="${SOFTWARE_WIDTH:-1280}"
SOFTWARE_HEIGHT="${SOFTWARE_HEIGHT:-720}"
SOFTWARE_FRAMERATE="${SOFTWARE_FRAMERATE:-24}"
SOFTWARE_CRF="${SOFTWARE_CRF:-30}"

HTTP_PORT="${HTTP_PORT:-3000}"
HTTPS_PORT="${HTTPS_PORT:-3001}"
SHM_SIZE="${SHM_SIZE:-2gb}"

READY_TIMEOUT="${READY_TIMEOUT:-240}"
TUNNEL_TIMEOUT="${TUNNEL_TIMEOUT:-90}"

ALLOWED_MAILS="${ALLOWED_MAILS:-}"   # Cloudflare email OTP allowlist
CONFIG_DIR="${CONFIG_DIR:-}"         # persisted /config (apps, files, history)
MOUNT_DIR="${MOUNT_DIR:-}"           # extra host dir, appears at /config/workspace
EXTRA_DOCKER_ARGS="${EXTRA_DOCKER_ARGS:-}"
# Ad-hoc Selkies tuning, e.g. 'SELKIES_VIDEO_CRF=18 SELKIES_MANUAL_WIDTH=1280'.
# Restricted to SELKIES_* keys so this can never smuggle in a docker flag.
EXTRA_SELKIES="${EXTRA_SELKIES:-}"

STATE_DIR="${DESKTOP_STATE_DIR:-${TMPDIR:-/tmp}/ubuntu-desktop-vnc}"
TUNNEL_LOG="$STATE_DIR/cloudflared.log"

TUNNEL_URL=""
TUNNEL_PID=""

# ----------------------------------------------------------------- utils ----
log()  { printf '\033[36m::\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24
  else
    # head closes the pipe early, which trips pipefail under SIGPIPE.
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true
  fi
}

# Status code for a URL, tolerating the container's self-signed certificate and
# falling back to wget on hosts without curl.
http_code() {
  local url="$1" code=""
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null) || code=""
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --spider --timeout=8 --no-check-certificate "$url" 2>/dev/null; then
      code=200
    else
      code=$(wget -S --spider --timeout=8 --no-check-certificate "$url" 2>&1 \
             | awk '/^  HTTP\//{c=$2} END{print c+0}')
    fi
  fi
  printf '%s' "${code:-000}"
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == "true" ]]
}

# Git Bash rewrites any POSIX-looking argument into a Windows path before it
# reaches docker.exe. That is correct for a bind mount source and completely
# wrong for a path that must stay inside the container (a -e value such as
# VK_ICD_FILENAMES). So: disable the rewrite wholesale, and convert the mount
# sources ourselves. A no-op on Linux, where cygpath does not exist.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

save_state() {
  mkdir -p "$STATE_DIR"
  {
    printf 'IMAGE=%q\n'     "$IMAGE_REPO:$FLAVOR"
    printf 'CONTAINER=%q\n'  "$CONTAINER"
    printf 'VNC_USER=%q\n'   "$VNC_USER"
    printf 'PASSWORD=%q\n'   "$PASSWORD"
    printf 'LOCAL_URL=%q\n'  "https://127.0.0.1:$HTTPS_PORT"
    printf 'PUBLIC_URL=%q\n' "$TUNNEL_URL"
  } >"$STATE_DIR/state.env.tmp"
  mv "$STATE_DIR/state.env.tmp" "$STATE_DIR/state.env"
}

load_state() {
  [[ -f "$STATE_DIR/state.env" ]] || die "no state in $STATE_DIR (run 'up' first)"
  # shellcheck disable=SC1090
  source "$STATE_DIR/state.env"
}

# Picks up CONTAINER/IMAGE from a previous run so 'down' works even when the
# original env vars are not set again.
load_state_if_present() {
  if [[ -f "$STATE_DIR/state.env" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_DIR/state.env"
  fi
}

# The container's abc user must own any bind-mounted config, or it silently
# fails to write and the desktop comes up with no home directory.
own_config_dir() {
  local dir="$1"
  mkdir -p "$dir"
  if [[ "$(stat -c '%u:%g' "$dir" 2>/dev/null || stat -f '%u:%g' "$dir")" != "$PUID:$PGID" ]]; then
    log "chown $dir to $PUID:$PGID for the in-container user"
    sudo chown -R "$PUID:$PGID" "$dir" 2>/dev/null \
      || chown -R "$PUID:$PGID" "$dir" 2>/dev/null \
      || warn "could not chown $dir; the desktop may not persist settings"
  fi
}

# -------------------------------------------------------------------- up ----
cmd_up() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  [[ -n "$PASSWORD" ]] || PASSWORD="$(gen_password)"

  local image="$IMAGE_REPO:$FLAVOR"
  mkdir -p "$STATE_DIR"

  # Any leftover blocks the name, not just a running one. A container left in
  # "exited" state is what you get after a failed step or a runner restart.
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "removing existing container '$CONTAINER'"
    docker rm -f "$CONTAINER" >/dev/null
  fi

  log "pulling $image"
  docker pull --quiet "$image" >/dev/null

  local -a args=(
    -d
    --name "$CONTAINER"
    --shm-size "$SHM_SIZE"
    -p "$HTTPS_PORT:$HTTPS_PORT"
    -p "$HTTP_PORT:$HTTP_PORT"
    -e "PUID=$PUID"
    -e "PGID=$PGID"
    -e "TZ=$TZ_NAME"
    -e "CUSTOM_USER=$VNC_USER"
    -e "PASSWORD=$PASSWORD"
    -e "TITLE=Ubuntu Desktop (${FLAVOR#ubuntu-})"
    # --- latency ---
    -e "SELKIES_AUDIO_FRAME_DURATION_MS=$AUDIO_FRAME_MS"
    -e "SELKIES_BACKPRESSURE_QUEUE_SIZE=$BACKPRESSURE"
    -e SELKIES_ENABLE_CLIPBOARD=true
    # Seamless clipboard sync triggers a paste prompt in Firefox and Safari.
    -e SELKIES_CLIPBOARD_SEAMLESS=false
  )

  if [[ "$SOFTWARE_RENDER" == "true" ]]; then
    log "software rendering: llvmpipe ${SOFTWARE_WIDTH}x${SOFTWARE_HEIGHT} @ ${SOFTWARE_FRAMERATE}fps cap"
    args+=(
      # Stop Selkies probing for an encode GPU that is not there.
      -e AUTO_GPU=false
      # Xvfb without DRI3; display capture falls back to shared memory.
      -e DISABLE_DRI3=true
      # Force CPU rasterisation for OpenGL, and software Vulkan via lavapipe.
      -e LIBGL_ALWAYS_SOFTWARE=1
      -e GALLIUM_DRIVER=llvmpipe
      -e MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
      -e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
      # Cap rather than merely default the framerate: a "24,8-24" range lets
      # the user lower it but stops them pinning 240fps and melting the CPU.
      -e "SELKIES_FRAMERATE=${SOFTWARE_FRAMERATE},8-${SOFTWARE_FRAMERATE}"
      # Higher CRF means fewer bits and less encoder work.
      -e "SELKIES_VIDEO_CRF=$SOFTWARE_CRF"
      # Paint-over at q90 is expensive and only matters for crisp text.
      -e SELKIES_USE_PAINT_OVER_QUALITY=false
      -e SELKIES_MANUAL_RESOLUTION=true
      -e SELKIES_ENABLE_RESIZE=false
      -e "SELKIES_MANUAL_WIDTH=$SOFTWARE_WIDTH"
      -e "SELKIES_MANUAL_HEIGHT=$SOFTWARE_HEIGHT"
    )
  else
    args+=(-e "SELKIES_FRAMERATE=$FRAMERATE")
  fi

  if [[ -n "$CONFIG_DIR" ]]; then
    own_config_dir "$CONFIG_DIR"
    log "persisting /config from $CONFIG_DIR"
    args+=(-v "$(host_path "$CONFIG_DIR"):/config")
  fi

  if [[ -n "$MOUNT_DIR" ]]; then
    [[ -d "$MOUNT_DIR" ]] || die "MOUNT_DIR does not exist: $MOUNT_DIR"
    log "mounting $MOUNT_DIR at /config/workspace"
    args+=(-v "$(host_path "$MOUNT_DIR"):/config/workspace")
  fi

  # Intentional word splitting: EXTRA_DOCKER_ARGS is a user-supplied passthrough
  # such as "--device /dev/dri/renderD128".
  if [[ -n "$EXTRA_DOCKER_ARGS" ]]; then
    # shellcheck disable=SC2206
    args+=($EXTRA_DOCKER_ARGS)
  fi

  if [[ -n "$EXTRA_SELKIES" ]]; then
    local -a tune=() kv
    for kv in $EXTRA_SELKIES; do
      case "$kv" in
        SELKIES_*=*) tune+=(-e "$kv") ;;
        *) die "EXTRA_SELKIES entries must look like SELKIES_FOO=bar, got '$kv'" ;;
      esac
    done
    log "applying Selkies overrides: ${EXTRA_SELKIES}"
    args+=("${tune[@]}")
  fi

  args+=("$image")

  log "starting container"
  MSYS2_ARG_CONV_EXCL='*' docker run "${args[@]}" >/dev/null

  log "waiting for the desktop to accept connections (${READY_TIMEOUT}s)"
  local deadline=$((SECONDS + READY_TIMEOUT)) ready=0
  while (( SECONDS < deadline )); do
    if ! container_running; then
      warn "container exited during startup, last log lines:"
      docker logs --tail 80 "$CONTAINER" >&2 || true
      die "desktop failed to start"
    fi
    case "$(http_code "https://127.0.0.1:$HTTPS_PORT")" in
      # 401 is the healthy answer: nginx is up and demanding the password.
      200|401|302) ready=1; break ;;
    esac
    sleep 3
  done
  (( ready )) || die "timed out waiting for the desktop on port $HTTPS_PORT"

  save_state
  log "desktop ready at https://127.0.0.1:$HTTPS_PORT as '$VNC_USER'"
}

# ---------------------------------------------------------------- tunnel ----
ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    return 0
  fi
  local arch tmp
  case "$(uname -m)" in
    x86_64|amd64)   arch=amd64 ;;
    aarch64|arm64)  arch=arm64 ;;
    *) die "unsupported architecture for cloudflared: $(uname -m)" ;;
  esac
  tmp=$(mktemp -d)
  log "installing cloudflared ($arch)"
  curl -fsSL --retry 3 \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" \
    -o "$tmp/cloudflared"
  chmod +x "$tmp/cloudflared"
  if ! sudo install -m 0755 "$tmp/cloudflared" /usr/local/bin/cloudflared 2>/dev/null; then
    install -m 0755 "$tmp/cloudflared" "$STATE_DIR/cloudflared"
    export PATH="$STATE_DIR:$PATH"
  fi
  rm -rf "$tmp"
  command -v cloudflared >/dev/null 2>&1 || die "failed to install cloudflared"
}

stop_tunnel() {
  if [[ -n "$TUNNEL_PID" ]]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
  fi
  if [[ -f "$STATE_DIR/tunnel.pid" ]]; then
    kill "$(cat "$STATE_DIR/tunnel.pid")" 2>/dev/null || true
    rm -f "$STATE_DIR/tunnel.pid"
  fi
  TUNNEL_PID=""
}

# One Quick Tunnel attempt against a single origin. Sets TUNNEL_URL on success.
try_origin() {
  local origin="$1"; shift
  TUNNEL_URL=""
  : >"$TUNNEL_LOG"
  log "requesting Cloudflare Quick Tunnel -> $origin"

  # nohup so the tunnel outlives the step that started it. Background processes
  # persist for the life of the job.
  nohup cloudflared tunnel --url "$origin" "$@" >>"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  printf '%s' "$TUNNEL_PID" >"$STATE_DIR/tunnel.pid"

  local deadline=$((SECONDS + TUNNEL_TIMEOUT))
  while (( SECONDS < deadline )); do
    local url
    url=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -n1 || true)
    if [[ -n "$url" ]]; then
      TUNNEL_URL="$url"
      return 0
    fi
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
      warn "cloudflared exited early"
      tail -n 15 "$TUNNEL_LOG" >&2 || true
      return 1
    fi
    sleep 2
  done

  warn "timed out waiting for a tunnel URL"
  tail -n 15 "$TUNNEL_LOG" >&2 || true
  stop_tunnel
  return 1
}

cmd_tunnel() {
  load_state
  ensure_cloudflared

  local -a mailargs=()
  if [[ -n "$ALLOWED_MAILS" ]]; then
    mailargs=(--allowed-mail "$ALLOWED_MAILS")
  fi

  # Prefer the container's HTTPS port. Its certificate is self-signed, so origin
  # verification has to be relaxed; the browser still sees a valid certificate
  # because cloudflared terminates TLS on the edge.
  if try_origin "https://127.0.0.1:$HTTPS_PORT" --no-tls-verify ${mailargs[@]+"${mailargs[@]}"}; then
    :
  elif try_origin "http://127.0.0.1:$HTTP_PORT" ${mailargs[@]+"${mailargs[@]}"}; then
    warn "using the plain HTTP origin fallback"
  else
    die "could not establish a tunnel; see $TUNNEL_LOG"
  fi

  save_state
  log "public URL: $TUNNEL_URL"

  # Quick Tunnels take a few seconds to propagate through the edge.
  local code=000 i
  for i in $(seq 1 10); do
    code=$(http_code "$TUNNEL_URL")
    [[ "$code" != "000" ]] && break
    sleep 5
  done
  case "$code" in
    000) warn "public URL not answering yet, may still be propagating. Try again shortly." ;;
    401) log  "public URL is up and password-protected (HTTP $code)" ;;
    *)   log  "public URL is up (HTTP $code)" ;;
  esac
}

# -------------------------------------------------------- down/status/etc ----
cmd_down() {
  load_state_if_present
  stop_tunnel
  if container_running; then
    log "stopping container '$CONTAINER'"
    docker rm -f "$CONTAINER" >/dev/null
  fi
  log "done"
}

cmd_status() {
  if container_running; then
    log "container: running"
  else
    warn "container: not running"
  fi
  if [[ -f "$STATE_DIR/state.env" ]]; then
    echo
    cat "$STATE_DIR/state.env"
  fi
  return 0
}

cmd_logs()  { docker logs --tail "${1:-200}" "$CONTAINER"; }
cmd_shell() { docker exec -it "$CONTAINER" bash; }

# Confirms which rasteriser is actually live inside the running desktop, rather
# than trusting the env vars we passed in.
cmd_glinfo() {
  container_running || die "container '$CONTAINER' is not running"
  # Bare "bash", not /bin/bash: Git Bash rewrites absolute POSIX paths into
  # Windows ones when handing arguments to docker.exe.
  docker exec "$CONTAINER" bash -lc '
    echo "=== OpenGL renderer ==="
    if command -v glxinfo >/dev/null 2>&1; then
      glxinfo -B 2>/dev/null | grep -E "Device|Accelerated|OpenGL core version"
    else
      echo "glxinfo absent (mesa-utils not installed)"
      echo "software driver present: $(ls /usr/lib/x86_64-linux-gnu/dri/swrast_dri.so 2>/dev/null || echo NO)"
    fi
    echo
    echo "=== rendering env ==="
    env | grep -E "LIBGL_ALWAYS_SOFTWARE|GALLIUM_DRIVER|MESA_LOADER_DRIVER|VK_ICD_FILENAMES" | sort
    echo
    echo "=== vcpu count ==="
    nproc
  '
}

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  case "${1:-}" in
    up)     cmd_up ;;
    tunnel) cmd_tunnel ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    logs)   cmd_logs "${2:-200}" ;;
    shell)  cmd_shell ;;
    glinfo) cmd_glinfo ;;
    *)      usage; exit 1 ;;
  esac
}

main "$@"