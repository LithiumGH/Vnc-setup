# Ubuntu Desktop in the browser, from GitHub Actions

Runs a real Ubuntu XFCE desktop on a GitHub-hosted runner and streams it to your
browser over HTTPS. No VPS, no port forwarding, no Cloudflare account.

```
your browser ──HTTPS──> Cloudflare edge ──tunnel──> ubuntu-latest runner
                                                        └─ webtop:ubuntu-xfce
                                                           (XFCE + Selkies)
```

## How it works

1. [`scripts/desktop.sh`](scripts/desktop.sh) starts `lscr.io/linuxserver/webtop`
   with your chosen flavor and publishes its port on the runner's loopback.
2. `cloudflared` opens a **Quick Tunnel** to that port. Quick Tunnels need no
   account and hand back a random `*.trycloudflare.com` URL. GitHub runners have
   no inbound ports, so an outbound tunnel is the only way in.
3. The URL and password are printed to the job summary.
4. A keep-alive step holds the job open until you cancel it.

This is **Selkies**, not noVNC. Selkies encodes the desktop as H.264 and decodes
it with the browser's WebCodecs API, so it moves a few hundred kbit/s instead of
the megabytes-per-second a raw framebuffer stream needs. That is where the
responsiveness comes from.

## Setup

```bash
cd vnc-ubuntu
git init && git add -A && git commit -m "browser ubuntu desktop"
gh repo create --private --source=. --push   # or push to any GitHub repo
```

Then **Actions → Ubuntu Desktop (browser VNC) → Run workflow**. The job summary
at the end of the run has the link and the password.

The repo has to exist on GitHub for Actions to run, but it can be almost empty.
Set it private: the tunnel URL is public to anyone who has it, and the desktop
includes a passwordless-sudo terminal.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `flavor` | `ubuntu-xfce` | Also `ubuntu-mate`, `ubuntu-kde`, `ubuntu-lxqt`, `ubuntu-i3` |
| `session_minutes` | `240` | Hard-capped at 355, GitHub's job limit is 360 |
| `password` | *(blank)* | Blank uses the `VNC_PASSWORD` secret, else generates one |
| `allowed_emails` | *(blank)* | Cloudflare one-time-PIN gate. Needs a real address and an interactive browser |
| `mount_workspace` | `true` | Your checkout appears at `/config/workspace` |
| `cache_config` | `true` | Caches `/config`, so installed apps survive the session |
| `software_render` | `true` | Force llvmpipe CPU rendering. Turn off only for real GPU hardware |
| `resolution` | `1280x720` | Pinned in software mode; must look like `WIDTHxHEIGHT` |

## Using it locally

Same script, no Actions. Useful for debugging a failure before you burn CI
minutes.

```bash
export FLAVOR=ubuntu-xfce CONFIG_DIR="$PWD/.desktop-config"
./scripts/desktop.sh up        # starts the container, waits until healthy
./scripts/desktop.sh tunnel    # prints a public https:// URL
./scripts/desktop.sh shell     # terminal inside the desktop
./scripts/desktop.sh logs 200
./scripts/desktop.sh down
```

The first run pulls ~1.2 GB and takes a few minutes. Needs a recent Docker;
no `--privileged` and no GPU required.

## Latency

Be realistic: the round trip from your browser to an Azure datacenter is 60-150 ms
and nothing in this setup can change that. Video feels fine because it is
inter-frame coded and low latency video is cheap; **clicks and keystrokes feel
the delay directly.**

The script already sets the two knobs that matter:

- `SELKIES_BACKPRESSURE_QUEUE_SIZE=30` — upstream defaults to 120 frames, which
  is ~2 s of video buffered ahead of you at 60 fps. This is the single biggest
  win.
- `SELKIES_AUDIO_FRAME_DURATION_MS=2.5` — keeps audio latency in step with video.

If clicks still feel sluggish, tune further:

```bash
BACKPRESSURE=15 ./scripts/desktop.sh up     # lower, but more dropped frames
```

If that is not good enough, the runner location is the problem, not the stack. Use
a [self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners)
on a VPS near you, or GitHub Codespaces, and point the same script at it. That
gets you to ~10-30 ms.

## Software rendering (and gaming)

There is no GPU on a GitHub runner, and there is no way to route your own GPU to
one — it is a VM in someone else's datacenter. So the desktop renders on the CPU
via **llvmpipe**, which the image already ships. Nothing extra to install.

Verified inside the running desktop:

```
Device: llvmpipe (LLVM 21.1.8, 256 bits)
Version: Mesa 26.0.8   GL 4.5 core profile   Accelerated: no
456 FPS (glxgears, 8 vCPU, 1280x720)
```

When `software_render` is on, the script sets:

| Setting | Value | Why |
|---|---|---|
| `LIBGL_ALWAYS_SOFTWARE`, `GALLIUM_DRIVER`, `MESA_LOADER_DRIVER_OVERRIDE` | `llvmpipe` | Force CPU rasterisation |
| `VK_ICD_FILENAMES` | `lvp_icd.json` | Software **Vulkan** (lavapipe) for titles that want Vulkan |
| `AUTO_GPU` | `false` | Stop Selkies probing for an encode GPU that isn't there |
| `DISABLE_DRI3` | `true` | Xvfb without GPU; capture falls back to shared memory |
| `SELKIES_MANUAL_WIDTH/HEIGHT` | `1280x720` | llvmpipe cost scales with pixel count |
| `SELKIES_FRAMERATE` | `24,8-24` | Capped, not just defaulted, so you can't pin 240fps |
| `SELKIES_VIDEO_CRF` | `30` | Fewer bits, less encoder work |
| `SELKIES_USE_PAINT_OVER_QUALITY` | `false` | Paint-over at q90 is expensive for little gain |

Verify it's live at any time:

```bash
./scripts/desktop.sh glinfo
```

**What this is good for.** Desktop apps, browsers, 2D games, older titles, indie
games with modest 3D. **What it isn't:** anything modern and 3D-heavy. Note also
that your 8-vCPU machine is not representative — Actions runners give you **2
vCPUs**, roughly a quarter of the fill rate above.

If you genuinely need a GPU, the only real answer is a rented GPU instance
(RunPod, Vast.ai) registered as a self-hosted runner, so the GPU sits in the
same machine as the runner. Then turn `software_render` off and pass the device
through with `EXTRA_DOCKER_ARGS="--device /dev/dri/renderD128"`.

## Mouse and keyboard

Verified against the shipped client bundle (`selkies-core.js`):

| Chord | Action |
|---|---|
| **Ctrl+Shift+X** | **Gaming mode** — this is the mouse lock you want |
| Ctrl+Shift+F | Toggle fullscreen |
| Ctrl+Shift+M | Toggle the sidebar (ignored while in gaming mode) |
| Ctrl+Shift+G | Toggle gamepad |
| Ctrl+Shift+click | Same as the active sidebar chord |

**Gaming mode** is what does what you're asking. It goes fullscreen, requests
**pointer lock** (the OS cursor disappears and the mouse is captured, so it can't
escape the window), and calls `navigator.keyboard.lock()` to trap Tab, Alt, and
Meta so the browser can't steal your keystrokes mid-game. Pointer lock is gated on
`gamingMode && isStreamFullscreen && inputAttached`, so all three happen together.

**Getting out:** press **Escape three times**. That's deliberate — a single press
would drop you out by accident mid-match. Two caveats:

- If your browser has no Keyboard Lock API, **one** Escape leaves gaming mode.
- Brave blocks the Keyboard API behind Shields, so one Escape there too.

Selkies detects this and shows you a notice telling you which case you're in,
rather than leaving you stuck.

Two things worth knowing:

- The chords are intercepted by the browser, so they never reach the desktop.
  Set `SELKIES_KEYBOARD_SHORTCUTS=false` if you'd rather they passed through.
- F11 (browser fullscreen) also works and is simpler, but it does **not** give
  you pointer lock — use Ctrl+Shift+X when you want the mouse captured.

## Security

- The Quick Tunnel URL is **unguessable but public**. Anyone with it reaches the
  login. Set `allowed_emails` for a one-time-PIN gate, or a strong `password`.
- Do not use a password you also use elsewhere.
- The desktop's terminal has passwordless sudo, so treat the URL like a password.
- Cancel the job to kill the tunnel immediately.

## Gotchas

**Password shows as `***`.** It came from the `VNC_PASSWORD` secret and GitHub
refuses to print secrets to logs. Pass it in the `password` input instead if you
need to read it back.

**`fatal: dubious ownership` in git.** The container's user is uid 1000 and the
runner checkout is uid 1001. Inside the desktop:

```bash
git config --global --add safe.directory /config/workspace
```

**Everything disappears when the job ends.** That is expected, unless
`cache_config` is on. Note the cache only restores your `~/.config` tree, not
anything installed outside it.

**Tunnel says "not answering yet".** Quick Tunnels take a few seconds to propagate
through the edge. The script already retries for 50 s; if it still fails, the
`Diagnostics` step prints the cloudflared log, which has the real error.

**The desktop is slow or blank.** Check the `Diagnostics` step. Software H.264
encoding on 2 vCPUs tops out well below 60 fps at large window sizes — shrink the
browser window, or pin the resolution:

```bash
EXTRA_SELKIES="SELKIES_MANUAL_RESOLUTION=true SELKIES_MANUAL_WIDTH=1280 SELKIES_MANUAL_HEIGHT=800" \
  ./scripts/desktop.sh up
```

Any `SELKIES_*` variable from the
[configuration reference](https://docs.linuxserver.io/selkies/user-guide/configuration/)
can be passed that way. Anything not starting with `SELKIES_` is rejected, so it
cannot be used to inject docker flags.

**6 hours is the ceiling.** GitHub kills hosted-runner jobs at 360 minutes.
Within that, cancel early to save minutes.

## What this is not

Stock Ubuntu Desktop is GNOME, and GNOME over a remote framebuffer is a bad time.
LinuxServer ships no GNOME image for good reason. XFCE is the closest thing to
the Ubuntu look that stays responsive at this distance. There is no
software-GL-accelerated 3D, and this is not a substitute for a GPU.