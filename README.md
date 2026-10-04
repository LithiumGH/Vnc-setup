# A Linux desktop in the browser, from GitHub Actions

Runs a real Linux desktop (XFCE by default, Ubuntu or Fedora or Debian or Arch)
on a GitHub-hosted runner and streams it to your browser over HTTPS. No VPS, no
port forwarding, no Cloudflare account.

```
your browser ──HTTPS──> Cloudflare edge ──tunnel──> ubuntu-latest runner
                                                        └─ webtop:<flavor>
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
git init && git add -A && git commit -m "browser linux desktop"
gh repo create --private --source=. --push   # or push to any GitHub repo
```

Then **Actions → Linux Desktop (browser VNC) → Run workflow**. The job summary
at the end of the run has the link and the password.

The repo has to exist on GitHub for Actions to run, but it can be almost empty.
Set it private: the tunnel URL is public to anyone who has it, and the desktop
includes a passwordless-sudo terminal.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `flavor` | `ubuntu-xfce` | `fedora-xfce`, `debian-xfce`, `arch-xfce`, plus `-mate`/`-kde`/`-i3`/`-lxqt` variants |
| `session_minutes` | `240` | Hard-capped at 355, GitHub's job limit is 360 |
| `password` | *(blank)* | Blank uses the `VNC_PASSWORD` secret, else generates one |
| `allowed_emails` | *(blank)* | Cloudflare one-time-PIN gate. Needs a real address and an interactive browser |
| `mount_workspace` | `true` | Your checkout appears at `/config/workspace` |
| `cache_config` | `true` | Caches `/config` (XFCE settings, home files — **not** installed software) |
| `software_render` | `true` | Force llvmpipe CPU rendering. Turn off only for real GPU hardware |
| `resolution` | `1280x720` | Pinned in software mode; must look like `WIDTHxHEIGHT` |
| `save_packages` | `true` | Snapshot installed packages to `desktop-packages.txt` at job end |

## Windows 11

**Not available as a Linux flavor**, and not for an obvious reason. LinuxServer's
webtop images are Linux containers; there is no Windows equivalent, because
Windows containers are Nano Server or Server Core and contain **no GUI stack** at
all — no DWM, no WPF, no shell.

GitHub does offer a `windows-11-arm` runner label, but:

- It is **ARM64**. Most Windows software is x64 and needs emulation.
- **cloudflared publishes no arm64 Windows build** (only 386/amd64), so the
  tunnelling binary itself has to run emulated.
- Streamed output needs a VNC/RDP server *plus* a capturable interactive desktop.
  A headless runner may only offer session 0, which captures a **black screen**
  regardless of which server you install.

Rather than guess, there is a **feasibility probe** workflow that answers this in
about two minutes. It downloads nothing, so a failure is a real signal rather
than a bad URL:

Actions → **Windows 11 feasibility probe** → **Run workflow**.

It reports a plain verdict:

| Verdict | Meaning |
|---|---|
| `VIABLE` | An interactive desktop exists and x86 emulation works — the streaming path is open |
| `BLOCKED: no interactive desktop` | Any VNC/RDP server captures a black screen. Stop here |
| `BLOCKED: no x86 emulation` | No tunnelling binary can run either |

Only build a Windows workflow after the probe says `VIABLE`.

## Using it locally

Same script, no Actions. Useful for debugging a failure before you burn CI
minutes.

```bash
export FLAVOR=fedora-xfce CONFIG_DIR="$PWD/.desktop-config"
./scripts/desktop.sh up         # starts the container, waits until healthy
./scripts/desktop.sh tunnel     # prints a public https:// URL
./scripts/desktop.sh shell      # terminal inside the desktop
./scripts/desktop.sh glinfo     # confirm llvmpipe / Vulkan ICD
./scripts/desktop.sh snapshot   # record newly installed packages
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

and on Fedora 44, software Vulkan comes up as:

```
deviceName = llvmpipe (LLVM 22.1.8, 256 bits)
driverInfo = Mesa 26.2.3
```

When `software_render` is on, the script sets:

| Setting | Value | Why |
|---|---|---|
| `LIBGL_ALWAYS_SOFTWARE`, `GALLIUM_DRIVER`, `MESA_LOADER_DRIVER_OVERRIDE` | `llvmpipe` | Force CPU rasterisation |
| `VK_ICD_FILENAMES` | distro-dependent | Software **Vulkan** (lavapipe). See the note below |
| `AUTO_GPU` | `false` | Stop Selkies probing for an encode GPU that isn't there |
| `DISABLE_DRI3` | `true` | Xvfb without GPU; capture falls back to shared memory |
| `SELKIES_MANUAL_WIDTH/HEIGHT` | `1280x720` | llvmpipe cost scales with pixel count |
| `SELKIES_FRAMERATE` | `24,8-24` | Capped, not just defaulted, so you can't pin 240fps |
| `SELKIES_VIDEO_CRF` | `30` | Fewer bits, less encoder work |
| `SELKIES_USE_PAINT_OVER_QUALITY` | `false` | Paint-over at q90 is expensive for little gain |

### Distro differences that actually bite

Not theoretical — both of these bit us and are handled in the script:

- **The lavapipe ICD filename differs.** Debian/Ubuntu ship
  `/usr/share/vulkan/icd.d/lvp_icd.json`; Fedora ships `lvp_icd.x86_64.json`.
  Pointing `VK_ICD_FILENAMES` at a file that doesn't exist breaks Vulkan outright
  rather than falling back, so the script picks per distro family. Override with
  `VULKAN_ICD=/path/to/icd.json`, or set `VULKAN_ICD=""` to let the loader choose.
- **The Mesa driver directory differs.** Debian/Ubuntu use the multiarch
  `/usr/lib/x86_64-linux-gnu/dri/`, Fedora uses `/usr/lib64/dri/`. The env vars
  above are driver-agnostic so rendering works either way, but anything you
  script against those paths must not hardcode them.

`desktop.sh glinfo` checks the ICD path actually exists, so a wrong guess shows
up as `MISSING` rather than as mysteriously broken Vulkan later.

Verify it any time:

```bash
./scripts/desktop.sh glinfo
```

> Note: `glxinfo` comes from `mesa-utils`, which **Fedora 44 no longer ships**.
> On Fedora use `vulkaninfo` (from `vulkan-tools`) to confirm the renderer.

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

## Persistent storage

**GitHub-hosted runners have none.** The VM and everything on its disk are
destroyed when the job ends. `/config` is the only volume in the image, measured
at **4.5 MB**; `/usr` is 3.2 GB and does not survive.

So do **not** try to snapshot the filesystem. `/usr` at 3.2 GB busts GitHub's
**100 MiB per-file limit**, and blows past both the Actions cache (10 GB/repo) and
artifact (500 MB) quotas. It's the wrong tool.

### What actually works: snapshot the package delta

Instead of storing files, store **which packages were added**, then reinstall them
next run. The manifest is tens of KB, reviewable in a diff, and reproducible.

```
Run 1:  baseline captured (914 packages in the Fedora image)
        you install fastfetch, cowsay, sl in the desktop
        job end -> snapshot -> commits desktop-packages.txt

Run 2:  baseline captured (914 packages)
        manifest found -> restores 4 packages automatically
        your tools are already there
```

Verified end-to-end on `fedora-xfce`: installed three packages, destroyed the
container, booted a fresh one, and confirmed all four (including the `yyjson`
dependency) came back.

**How to use it**

- `save_packages` input (default on) commits the manifest at job end
- `./scripts/desktop.sh snapshot` does the same thing locally
- Edit `desktop-packages.txt` by hand to pin a specific list — the script installs
  whatever is in it, so you can review or pre-seed it

The manifest records *every* new package, dependencies included, so restore is a
single idempotent transaction. Names only, no versions — so a base image update
gets newer versions rather than pinning you to stale ones.

### Two things to know

- **Cancelling the job skips the snapshot.** The step only runs on normal
  completion. Let the session window elapse, or run `snapshot` manually.
- **The commit needs `contents: write`**, which the job requests. If you protect
  `main`, the push is refused and the step logs a warning rather than failing.
  Commit the manifest yourself, or allow GitHub Actions to write.

### The other mechanisms

| You want to keep | Use | Why |
|---|---|---|
| **Code and config files** | **Commit to the repo** | Already mounted at `/config/workspace` |
| **XFCE settings, dotfiles** | `cache_config` | 4.5 MB, fits easily |
| **Installed software** | `desktop-packages.txt` (above) | Tiny, reviewable, reproducible |
| **Non-package files** (`/opt`, a binary in `/usr/local`) | Custom image | See below |
| **Large generated data** | `actions/upload-artifact` | 90-day retention, 500 MB free |

For anything the package manager can't express, bake it into an image:

```dockerfile
FROM lscr.io/linuxserver/webtop:fedora-xfce
RUN dnf install -y --nodocs gimp inkscape && dnf clean all
```

```bash
IMAGE_REPO=ghcr.io/you/vnc-desktop FLAVOR=latest ./scripts/desktop.sh up
```

> Fedora 44 has **dropped `neofetch`** upstream — use `fastfetch` instead. Worth
> remembering generally: a package that exists on Ubuntu may not exist on Fedora.

### If you need real persistence

A [self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners)
has an actual disk. Everything in this repo works unchanged against one.

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