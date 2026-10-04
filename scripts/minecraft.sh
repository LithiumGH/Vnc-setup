#!/usr/bin/env bash
#
# Minecraft tuning for CPU-only (llvmpipe) rendering.
#
# Commands: status | deps | options | launch
#
# There is no GPU on a GitHub runner, so Minecraft is rendered by llvmpipe on the
# same two vCPUs that are already busy with chunk meshing, the H.264 encoder and
# everything else. Smoothness therefore comes almost entirely from doing *less
# work*, not from faster hardware.
#
# The four levers that matter, in order of how much they actually buy:
#
#   1. Cap Minecraft's FPS to the stream rate. Uncapped, Minecraft on llvmpipe
#      will happily render 100+ fps that Selkies then throws away. Every extra
#      frame is pure waste, and it competes with the encoder for CPU. This is
#      the single biggest win and the most commonly missed.
#   2. Render distance. Chunk meshing dominates CPU cost and scales with the
#      cube of the radius: 4 chunks does about a fifth the work of 12.
#   3. Graphics: Fast, no shaders. llvmpipe executes every shader instruction on
#      the CPU, so shader packs are close to a slideshow.
#   4. Field of view. Halving the horizontal FOV roughly halves the area to
#      rasterise. 70 -> 60 is a cheap ~27% cut that most players never notice.
#
set -Eeuo pipefail

CONTAINER="${CONTAINER:-ubuntu-desktop}"
# Where to keep the game. /config is the persisted volume, so a downloaded
# Minecraft survives session teardown instead of being re-fetched every run.
GAME_DIR="${GAME_DIR:-/config/minecraft}"

log()  { printf '\033[36m::\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# Mirror the desktop's render preset so Minecraft's FPS cap matches what the
# stream can actually deliver. Rendering faster than the encoder is pointless.
preset_fps() {
  case "${RENDER_PRESET:-balanced}" in
    quality)  echo 30 ;;
    balanced) echo 24 ;;
    fast)     echo 20 ;;
    potato)   echo 15 ;;
    tiny)     echo 12 ;;
    *)        echo 24 ;;
  esac
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true
}

need_container() {
  container_running || die "container '$CONTAINER' is not running; start it with scripts/desktop.sh up"
}

cmd_status() {
  if ! container_running; then
    log "container '$CONTAINER' is not running"
    log "start it:  ./scripts/desktop.sh up"
    return 0
  fi

  echo
  echo "=== Java ==="
  if docker exec "$CONTAINER" bash -lc 'command -v java' >/dev/null 2>&1; then
    docker exec "$CONTAINER" bash -lc 'java -version 2>&1' | sed 's/^/  /'
  else
    echo "  not installed -- run: $0 deps"
  fi

  echo
  echo "=== resources as the game will see them ==="
  # This is the number that decides whether the game is viable at all, so read
  # it from inside the container rather than assuming the host's.
  local mem_cpus
  mem_cpus=$(docker exec "$CONTAINER" bash -lc \
    'echo "$(nproc) $(free -m | awk "/^Mem:/ {print \$7}")"')
  local cpus="${mem_cpus%% *}" avail_mb="${mem_cpus##* }"
  echo "  cpus:            $cpus"
  echo "  memory available: ${avail_mb} MiB"
  echo "  stream preset:   ${RENDER_PRESET:-balanced} @ $(preset_fps) fps cap"

  echo
  echo "=== gpu ==="
  docker exec "$CONTAINER" bash -lc \
    'echo "  LIBGL_ALWAYS_SOFTWARE=$LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER=$GALLIUM_DRIVER LP_NUM_THREADS=$LP_NUM_THREADS"' 2>/dev/null \
    || true
  echo "  llvmpipe: all rasterisation on the CPU, nothing faster available"

  echo
  echo "=== game files ==="
  if docker exec "$CONTAINER" bash -lc "test -d '$GAME_DIR'" 2>/dev/null; then
    # | as the sed delimiter: GAME_DIR starts with /, which would close a s///.
    docker exec "$CONTAINER" bash -lc \
      "du -sh '$GAME_DIR' 2>/dev/null | sed \"s|^|  $GAME_DIR |\"; ls -1 '$GAME_DIR' 2>/dev/null | sed 's|^|  - |'" || true
  else
    echo "  $GAME_DIR not created yet"
  fi

  if [[ -z "${avail_mb%%[!0-9]*}" || "${avail_mb%%[!0-9]*}" -lt 1200 ]]; then
    warn "under ~1200 MiB available. Minecraft needs about 1.5G minimum; expect failures"
  fi
  if [[ "$cpus" -lt 4 ]]; then
    warn "only $cpus vCPU. Playable at low settings, but expect stutter in crowds"
  fi
}

cmd_deps() {
  need_container
  log "installing a headless JRE plus the tools Minecraft needs to unpack itself"
  # xz-utils: modern Minecraft jars are xz-compressed and will not extract
  # without it, which is a confusing "cannot open jar" failure.
  docker exec -u root "$CONTAINER" bash -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y --nodocs java-21-openjdk-headless xz
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y --no-install-recommends openjdk-21-jre-headless xz-utils
    elif command -v pacman >/dev/null 2>&1; then
      pacman -S --noconfirm --needed jre-openjdk-headless xz
    else
      echo "no supported package manager" >&2; exit 1
    fi' || die "package install failed"

  docker exec -u root "$CONTAINER" bash -lc "mkdir -p '$GAME_DIR' && chown 1000:1000 '$GAME_DIR'"

  log "installed:"
  docker exec "$CONTAINER" bash -lc 'java -version 2>&1' | sed 's/^/  /'
  log "game dir: $GAME_DIR (persisted under /config)"
  cat <<'EOF'

To keep Java across sessions, add it to the manifest so desktop.sh restores it
every run:

    echo java-21-openjdk-headless >> desktop-packages.txt   # Fedora / Debian / Arch name
    echo openjdk-21-jre-headless    >> desktop-packages.txt   # Ubuntu name

Then run:  ./scripts/minecraft.sh options
EOF
}

cmd_options() {
  need_container
  local fps; fps=$(preset_fps)

  log "writing CPU-tuned options.txt (fps capped to $fps to match the stream)"
  cat >"$TMP_OPTS" <<EOF
# Generated by scripts/minecraft.sh -- tuned for llvmpipe, no GPU.
# Minecraft ignores keys it does not recognise, so extra ones are harmless.
version:3465

# --- the big ones ---
# Cap to the stream rate. Uncapped, Minecraft renders frames that are dropped
# before they are ever encoded, wasting CPU the encoder needs.
maxFps:$fps
enableVsync:false
# Chunk meshing scales with the cube of this radius. 12 -> 4 is roughly a fifth
# of the work and is the difference between usable and not.
renderDistance:4
simulationDistance:3

# --- graphics ---
# 0 = Fast. Fancy lighting is per-pixel work on the CPU.
graphicsMode:0
# Halving horizontal FOV roughly halves the rasterised area. 70 -> 60 costs
# about 27% of the pixels and most players do not notice.
fov:60.0
# No mipmaps: saves the memory churn of generating them per texture.
mipmapLevels:0
# Biome blending is another per-column pass over every visible chunk.
biomeBlendRadius:0

# --- everything that draws extra geometry or extra passes ---
particles:2
ao:false
entityShadows:false
screenEffectScale:0.0
# Fullscreen-ish shaders are hopeless without a GPU; make that explicit so
# nobody wastes time trying them.
shaders:false

# --- housekeeping ---
pauseOnLostFocus:false
narrator:0
tutorialStep:none
skipMultiplayerWarning:true
darkMojangStudiosBackground:false
glDebugVerbosity:0
# Raise brightness in-game instead of reaching for a mod, which costs frames.
gamma:1.0
EOF

  local dest=".minecraft/options.txt"
  # -i is required: without it docker exec closes stdin immediately and the
  # heredoc arrives as zero bytes, producing a silently empty options.txt.
  docker exec -i -u root "$CONTAINER" bash -lc "
    set -e
    # Only the parent directory, or mkdir -p would create options.txt as a
    # directory and the write below would fail with 'Is a directory'.
    mkdir -p '$GAME_DIR/.minecraft'
    cat > '$GAME_DIR/$dest'
    chown -R 1000:1000 '$GAME_DIR'
    rm -f '$GAME_DIR/options.txt.bak'
  " <"$TMP_OPTS" || die "could not write options.txt"
  rm -f "$TMP_OPTS"

  cat <<EOF

  wrote $GAME_DIR/$dest

  If you have already played, Minecraft will have its own settings file in the
  instance directory (Prism: ~/.local/share/PrismLauncher/instances/*/minecraft/).
  Copy this over it, or edit the values there directly:

    renderDistance:4   simulationDistance:3   maxFps:$fps
    graphicsMode:0     fov:60.0               shaders:false

  Biggest three wins, if you only change three things:
    1. maxFps down to $fps   (stops rendering frames nobody sees)
    2. renderDistance 4      (chunk meshing dominates CPU)
    3. shaders off, graphics Fast
EOF
}

cmd_launch() {
  need_container
  [[ $# -ge 1 ]] || die "usage: $0 launch <path-to-launcher-or-jar> [args...]"

  # Heap must be set explicitly. Minecraft's own default is usually larger than
  # the container's available memory, so it would sit in GC thrash instead.
  # SerialGC beats G1 here: small heap, and G1's concurrent threads are pure
  # overhead when there are only two vCPUs to begin with.
  #
  # JAVA_TOOL_OPTIONS rather than splicing flags into a shell string, so the JVM
  # picks them up whichever java binary it resolves and no quoting mistake can
  # turn one flag into two.
  local jvm_opts="-Xms512M -Xmx1400M -XX:+UseSerialGC -XX:MaxMetaspaceSize=192M"
  jvm_opts+=" -Dfile.encoding=UTF-8 -Dorg.lwjgl.system.NoChecks=true"

  log "launching $target"
  log "  jvm: $jvm_opts"
  log "  graphics will be llvmpipe (CPU). expect low fps; see '$0 status'"

  docker exec -u 1000:1000 \
    -e DISPLAY="${DISPLAY:-:1}" \
    -e JAVA_TOOL_OPTIONS="$jvm_opts" \
    -w "$GAME_DIR" \
    "$CONTAINER" bash -lc '
      set -e
      target="$1"; shift
      case "$target" in
        *.jar) exec java -jar "$target" "$@" ;;
        *)     exec "$target" "$@" ;;
      esac
    ' _ "$target" "$@"
}

TMP_OPTS="$(mktemp -t mc-opts.XXXXXX)"
trap 'rm -f "$TMP_OPTS"' EXIT

case "${1:-status}" in
  status)  shift; cmd_status "$@" ;;
  deps)    shift; cmd_deps "$@" ;;
  options) shift; cmd_options "$@" ;;
  launch)  shift; cmd_launch "$@" ;;
  -h|--help|help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (try: status | deps | options | launch)" ;;
esac