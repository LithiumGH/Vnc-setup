#!/usr/bin/env bash
#
# Browser-based Linux desktop for GitHub Actions (or any local Docker host).
#
# Streams a Linux desktop to the browser using Selkies, which encodes
# H.264 with WebCodecs. That is dramatically lower latency than classic noVNC
# framebuffer streaming, which sends raw rectangles as PNG/JPEG.
#
# GitHub runners have no inbound ports, so the container is published through a
# Cloudflare Quick Tunnel: no account needed, and it hands back real HTTPS,
# which Selkies requires for WebCodecs to be available in the browser.
#
# Commands: up | tunnel | down | status | logs | shell | glinfo | snapshot
#
set -Eeuo pipefail

# ----------------------------------------------------------------- utils ----
# Defined before the config block because the config below validates its own
# input and needs to be able to fail loudly rather than silently carry on.
log()  { printf '\033[36m::\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- config ----
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
IMAGE_REPO="${IMAGE_REPO:-lscr.io/linuxserver/webtop}"
FLAVOR="${FLAVOR:-fedora-xfce}"
CONTAINER="${CONTAINER:-ubuntu-desktop}"

# What we actually run. Resolved inside cmd_up (derived flavors are built as a
# local tag rather than pulled) and recorded in state.env so later steps such
# as the tunnel here and the job summary there report the truthful name.
IMAGE=""

# Flavors that are not published upstream as an image tag. Mint is the case:
# LinuxServer ships no Mint image, so mint-cinnamon derives their published
# Ubuntu image with Cinnamon (the Mint desktop) added. Each entry names a
# Dockerfile under scripts/; the build happens in cmd_up before any run.
flavor_dockerfile() {
  case "$FLAVOR" in
    mint-cinnamon) echo "$SCRIPT_DIR/mint-cinnamon.Dockerfile" ;;
    *)             echo "" ;;
  esac
}

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

# Render presets for CPU-only rasterisation.
#
# llvmpipe's cost is roughly pixels x frames, so resolution is by far the
# biggest lever: 854x480 is 410k pixels against 720p's 922k, so about 55% less
# work for the same scene. Anything set explicitly below overrides the preset.
#
# CSS scaling makes the browser stretch the small framebuffer to fill the
# window, so the view stays full-screen while only the low-res pixels are ever
# encoded. That cuts CPU and bandwidth together.
RENDER_PRESET="${RENDER_PRESET:-balanced}"
CSS_SCALE="${CSS_SCALE:-auto}"
if [[ "$SOFTWARE_RENDER" == "true" ]]; then
  case "$RENDER_PRESET" in
    quality)   preset_w=1920; preset_h=1080; preset_fps=30; preset_crf=22; preset_css=1 ;;
    balanced)  preset_w=1280; preset_h=720;  preset_fps=24; preset_crf=28; preset_css=1 ;;
    fast)      preset_w=960;  preset_h=540;  preset_fps=20; preset_crf=30; preset_css=1 ;;
    potato)    preset_w=854;  preset_h=480;  preset_fps=15; preset_crf=34; preset_css=1 ;;
    tiny)      preset_w=640;  preset_h=360;  preset_fps=12; preset_crf=36; preset_css=1 ;;
    *) die "RENDER_PRESET must be quality|balanced|fast|potato|tiny, got '$RENDER_PRESET'" ;;
  esac
else
  # A real GPU does not need the CPU budget the presets encode, so only the
  # desktop size carries over. Framerate and CRF are left generous, since
  # clamping them is the presets' job and it would just hobble the GPU.
  preset_w=1920; preset_h=1080; preset_fps=60; preset_crf=23; preset_css=0
  log "GPU rendering: ignoring the $RENDER_PRESET CPU budget"
fi

SOFTWARE_WIDTH="${SOFTWARE_WIDTH:-$preset_w}"
SOFTWARE_HEIGHT="${SOFTWARE_HEIGHT:-$preset_h}"
SOFTWARE_FRAMERATE="${SOFTWARE_FRAMERATE:-$preset_fps}"
SOFTWARE_CRF="${SOFTWARE_CRF:-$preset_crf}"
if [[ "$CSS_SCALE" == "auto" ]]; then
  # Below 1080p, upscale in the browser rather than paying to render more.
  CSS_SCALE=$preset_css
fi

# llvmpipe thread count. Left unset by default so Mesa picks for itself.
#
# NOTE: this was previously defaulted to "nproc - 1" on the theory that llvmpipe
# would starve the encoder. Measured, that was wrong: a fixed render at 1, 2, 4
# and 8 threads took the same wall-clock time, so setting it made no difference
# on the host it was tested on. It stays overridable because it is the
# documented Mesa variable and does matter on some builds -- but it is not
# claimed to be a win here.
LP_NUM_THREADS="${LP_NUM_THREADS:-}"

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

# Set VULKAN_ICD="" to skip forcing the software Vulkan ICD; it is resolved in
# cmd_up, not here, because vulkan_icd() is defined further down this file.
VULKAN_ICD="${VULKAN_ICD-}"

# Where the list of extra packages to install lives. Relative paths resolve
# against the current directory, so running from the repo root puts this beside
# the workflow and it can be committed for the next run.
PACKAGE_MANIFEST="${PACKAGE_MANIFEST:-./desktop-packages.txt}"

STATE_DIR="${DESKTOP_STATE_DIR:-${TMPDIR:-/tmp}/ubuntu-desktop-vnc}"
TUNNEL_LOG="$STATE_DIR/cloudflared.log"

TUNNEL_URL=""
TUNNEL_PID=""

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
  # Fallback for any path that saves before cmd_up resolved the real image.
  if [[ -z "$IMAGE" ]]; then IMAGE="$IMAGE_REPO:$FLAVOR"; fi
  {
    printf 'IMAGE=%q\n'     "$IMAGE"
    printf 'CONTAINER=%q\n'  "$CONTAINER"
    printf 'VNC_USER=%q\n'   "$VNC_USER"
    printf 'PASSWORD=%q\n'   "$PASSWORD"
    printf 'LOCAL_URL=%q\n'  "https://127.0.0.1:$HTTPS_PORT"
    printf 'PUBLIC_URL=%q\n' "$TUNNEL_URL"
    # Render settings, so later steps (the job summary) can report what the
    # session actually used rather than re-deriving it from inputs.
    printf 'SOFTWARE_RENDER=%q\n' "$SOFTWARE_RENDER"
    printf 'SOFTWARE_WIDTH=%q\n'  "$SOFTWARE_WIDTH"
    printf 'SOFTWARE_HEIGHT=%q\n' "$SOFTWARE_HEIGHT"
    printf 'SOFTWARE_FRAMERATE=%q\n' "$SOFTWARE_FRAMERATE"
    printf 'SOFTWARE_CRF=%q\n'   "$SOFTWARE_CRF"
    printf 'LP_NUM_THREADS=%q\n' "$LP_NUM_THREADS"
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
  local dockerfile; dockerfile="$(flavor_dockerfile)"
  IMAGE="$image"

  # The Dockerfile FROM is hardcoded to the published Ubuntu tag, so the same
  # tag has to be pre-pulled: without --pull the build reuses whatever is
  # local, which may be stale or absent, and that is not deterministic.
  local base_tag="lscr.io/linuxserver/webtop:ubuntu-xfce"

  if [[ -n "$dockerfile" ]]; then
    [[ -f "$dockerfile" ]] || die "derived flavor '$FLAVOR' has no Dockerfile at $dockerfile"
    log "pulling $base_tag (base of the $FLAVOR build)"
    docker pull --quiet "$base_tag" >/dev/null
    log "building $image from $(basename "$dockerfile") (the Cinnamon install adds a few minutes)"
    docker build -f "$dockerfile" -t "$image" "$SCRIPT_DIR/.." >&2 || die "build failed for $FLAVOR"
  else
    log "pulling $image"
    docker pull --quiet "$image" >/dev/null
  fi

  mkdir -p "$STATE_DIR"

  # Any leftover blocks the name, not just a running one. A container left in
  # "exited" state is what you get after a failed step or a runner restart.
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "removing existing container '$CONTAINER'"
    docker rm -f "$CONTAINER" >/dev/null
  fi

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
    -e "TITLE=$(flavor_label)"
    # --- latency ---
    -e "SELKIES_AUDIO_FRAME_DURATION_MS=$AUDIO_FRAME_MS"
    -e "SELKIES_BACKPRESSURE_QUEUE_SIZE=$BACKPRESSURE"
    -e SELKIES_ENABLE_CLIPBOARD=true
    # Seamless clipboard sync triggers a paste prompt in Firefox and Safari.
    -e SELKIES_CLIPBOARD_SEAMLESS=false
  )

  if [[ "$SOFTWARE_RENDER" == "true" ]]; then
    local icd="${VULKAN_ICD:-$(vulkan_icd)}"
    # Quantify the saving against 1080p so the preset is a known trade, not a
    # guess: llvmpipe work scales with pixels x frames.
    local px=$((SOFTWARE_WIDTH * SOFTWARE_HEIGHT))
    local px1080=$((1920 * 1080))
    local pct=$((px * 100 / px1080))
    local cores
    cores=$(nproc 2>/dev/null || echo "?")
    log "software rendering: llvmpipe ${SOFTWARE_WIDTH}x${SOFTWARE_HEIGHT} @ ${SOFTWARE_FRAMERATE}fps"
    log "  ${cores} vCPU, ${pct}% of 1080p pixel work per frame${LP_NUM_THREADS:+, $LP_NUM_THREADS llvmpipe threads}"
    (( CSS_SCALE == 1 )) && log "  browser upscales the framebuffer, so the view stays full window"
    args+=(
      # Stop Selkies probing for an encode GPU that is not there.
      -e AUTO_GPU=false
      # Xvfb without DRI3; display capture falls back to shared memory.
      -e DISABLE_DRI3=true
      # Force CPU rasterisation for OpenGL.
      -e LIBGL_ALWAYS_SOFTWARE=1
      -e GALLIUM_DRIVER=llvmpipe
      -e MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
      # Capped rather than merely default the framerate: a "24,8-24" range lets
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
    # Stretch the small framebuffer across the browser window instead of
    # rendering at window size. The client scales it, so only the low-res
    # pixels are ever encoded.
    if [[ "$CSS_SCALE" == "1" ]]; then
      args+=(-e SELKIES_USE_CSS_SCALING=true)
    fi
    # llvmpipe picks its own thread count by default; be explicit.
    if [[ -n "$LP_NUM_THREADS" ]]; then
      args+=(-e "LP_NUM_THREADS=$LP_NUM_THREADS")
    fi
    # An empty VK_ICD_FILENAMES is worse than omitting it, so only pass it when
    # we resolved a real path.
    if [[ -n "$icd" ]]; then
      args+=(-e "VK_ICD_FILENAMES=$icd")
    else
      log "VULKAN_ICD empty, leaving the Vulkan loader to choose"
    fi
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

  # Baseline first: whatever we restore on top of this run is exactly what the
  # user added on top of that, which is what 'snapshot' diffs against.
  if installed_packages >"$STATE_DIR/packages-baseline.txt" && [[ -s "$STATE_DIR/packages-baseline.txt" ]]; then
    log "baseline: $(wc -l <"$STATE_DIR/packages-baseline.txt") packages in the base image"
  else
    warn "could not enumerate baseline packages; snapshot will not be accurate"
  fi

  if [[ -f "$PACKAGE_MANIFEST" ]]; then
    install_packages "$PACKAGE_MANIFEST" || warn "continuing despite package restore failure"
  fi

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

# Human label for the browser tab, from a flavor name like "fedora-xfce".
# "latest" is XFCE on Alpine, so name that one explicitly.
flavor_label() {
  local base de
  case "$FLAVOR" in
    latest) echo "Alpine XFCE"; return ;;
    *-*)    base="${FLAVOR%-*}"; de="${FLAVOR##*-}" ;;
    *)      echo "$FLAVOR"; return ;;
  esac
  printf '%s %s\n' \
    "$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')" \
    "$(printf '%s' "$de"   | tr '[:lower:]' '[:upper:]')"
}

# Mesa's software Vulkan (lavapipe) ICD file is named differently per distro:
# verified Debian/Ubuntu ship lvp_icd.json, Fedora ships lvp_icd.x86_64.json.
# Pointing VK_ICD_FILENAMES at a file that does not exist breaks Vulkan rather
# than falling back, so this has to be right per distro family.
# Set VULKAN_ICD="" to skip forcing it and let the loader choose.
vulkan_icd() {
  case "$FLAVOR" in
    fedora-*|rocky-*|alma-*|centos-*) echo "/usr/share/vulkan/icd.d/lvp_icd.x86_64.json" ;;
    *)                                echo "/usr/share/vulkan/icd.d/lvp_icd.json" ;;
  esac
}

# --------------------------------------------------------- packages ----
# Persistence strategy: never try to snapshot the filesystem. /usr is 3.2 GB,
# which busts GitHub's 100 MiB per-file limit and blows the Actions cache and
# artifact quotas. Instead record *which packages* were added, and reinstall
# those next run. The manifest is a few tens of KB, reviewable in a diff, and
# reproducible.

# Every installed package name, sorted, for whatever distro is in the container.
# The full set is captured at startup as the baseline, so the difference later is
# exactly what the user added (explicit packages plus their dependencies).
installed_packages() {
  docker exec "$CONTAINER" bash -lc '
    if command -v rpm >/dev/null 2>&1; then
      rpm -qa --qf "%{NAME}\n"
    elif command -v dpkg-query >/dev/null 2>&1; then
      dpkg-query -f "\${binary:Package}\n" -W
    elif command -v pacman >/dev/null 2>&1; then
      pacman -Qq
    else
      echo "unknown package manager" >&2; exit 1
    fi' 2>/dev/null | tr -d '\r' | sed '/^$/d' | sort -u
}

install_packages() {
  local file="$1" count
  count=$(grep -cve '^\s*#' -e '^\s*$' "$file" || true)
  (( count > 0 )) || { log "package manifest is empty, nothing to restore"; return 0; }

  log "restoring $count package(s) from $(basename "$file") (this takes a few minutes)"
  local pkgs
  pkgs=$(grep -ve '^\s*#' -e '^\s*$' "$file" | tr '\n' ' ')

  docker exec "$CONTAINER" bash -lc "
    set -e
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y --nodocs $pkgs
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y --no-install-recommends $pkgs
    elif command -v pacman >/dev/null 2>&1; then
      pacman -S --noconfirm --needed $pkgs
    else
      echo 'no supported package manager in container' >&2; exit 1
    fi" || {
      warn "some packages failed to install; the desktop is still usable"
      return 1
    }
  log "packages restored"
}

cmd_snapshot() {
  container_running || die "container '$CONTAINER' is not running"
  local baseline="$STATE_DIR/packages-baseline.txt"
  [[ -f "$baseline" ]] || die "no baseline captured; run 'up' first in this session"

  local current="$STATE_DIR/packages-current.txt"
  installed_packages >"$current"
  [[ -s "$current" ]] || die "could not enumerate installed packages"

  # Packages present now that were not in the baseline == what the user added.
  local added="$STATE_DIR/packages-added.txt"
  comm -23 "$current" "$baseline" >"$added"

  local count
  count=$(grep -c . "$added" || true)
  if (( count == 0 )); then
    log "no new packages since startup"
    [[ -f "$PACKAGE_MANIFEST" ]] || return 0
  fi

  local dir; dir=$(dirname "$PACKAGE_MANIFEST")
  [[ -d "$dir" ]] || { warn "manifest dir '$dir' missing, not writing"; return 1; }

  {
    echo "# Packages added inside the desktop, reinstalled on the next run."
    echo "# Regenerate with: ./scripts/desktop.sh snapshot"
    echo "# One package per line; lines starting with # are ignored."
    cat "$added"
  } >"$PACKAGE_MANIFEST"

  log "wrote $count package(s) to $PACKAGE_MANIFEST"
  if (( count > 0 )); then
    log "added: $(tr '\n' ' ' <"$added" | cut -c1-300)"
  fi
}

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
      # Driver dir differs by distro: Debian/Ubuntu is multiarch, Fedora is lib64.
      echo "software driver: $(ls /usr/lib*/dri/swrast_dri.so /usr/lib/*/dri/swrast_dri.so 2>/dev/null | head -1 || echo NOT FOUND)"
    fi
    echo
    echo "=== rendering env ==="
    env | grep -E "LIBGL_ALWAYS_SOFTWARE|GALLIUM_DRIVER|MESA_LOADER_DRIVER|VK_ICD_FILENAMES" | sort
    echo
    echo "=== software Vulkan ICD ==="
    icd="${VK_ICD_FILENAMES:-}"
    if [ -z "$icd" ]; then
      echo "VK_ICD_FILENAMES not set, loader will choose"
    elif [ -f "$icd" ]; then
      echo "OK      $icd"
    else
      echo "MISSING $icd  <-- Vulkan will fail; the filename differs per distro"
    fi
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
    snapshot) cmd_snapshot ;;
    *)      usage; exit 1 ;;
  esac
}

main "$@"