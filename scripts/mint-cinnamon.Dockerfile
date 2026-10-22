# Linux Mint desktop, derived from the published Ubuntu webtop image.
#
# LinuxServer ships no Mint tag and Mint itself publishes no container image
# with a desktop, so the reliable way to get the Mint look is Cinnamon — Mint's
# own desktop — installed from Ubuntu's universe repository, which packages it
# for the exact release this image is built on.
#
# The desktop to start is not chosen at runtime: each webtop flavor hardcodes
# its session in /defaults/startwm.sh, which svc-de/run execs on every boot.
# That file is never copied into the persistent /config, so overwriting it here
# switches the whole desktop to Cinnamon even on a reused cached volume.
#
# Built automatically by scripts/desktop.sh when FLAVOR=mint-cinnamon.
FROM lscr.io/linuxserver/webtop:ubuntu-xfce

ENV TITLE="Linux Mint Cinnamon"

RUN \
  echo "**** install Cinnamon (the Mint desktop) ****" && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive \
  apt-get install --no-install-recommends -y \
    cinnamon-desktop-environment && \
  echo "**** keep the screen reachable (no lock screen) ****" && \
  # The XFCE build already removed xscreensaver's autostart; do the same for
  # Cinnamon's, which would lock the browser-side desktop after an idle gap.
  rm -f /etc/xdg/autostart/cinnamon-screensaver.desktop && \
  echo "**** point the session at Cinnamon ****" && \
  printf '%s\n' \
    '#!/bin/bash' \
    '' \
    '# Start DE' \
    '# Same shape as the XFCE file below: the session runs on a session bus.' \
    'exec dbus-launch --exit-with-session /usr/bin/cinnamon-session > /dev/null 2>&1' \
    > /defaults/startwm.sh && \
  chmod 0755 /defaults/startwm.sh && \
  printf '%s\n' \
    '#!/usr/bin/with-contenv bash' \
    '' \
    '# Cinnamon has no supported Wayland mode in this setup, so ignoring the' \
    '# switch beats silently booting the XFCE session this image ships.' \
    'echo "[startwm_wayland] Wayland is not supported for mint-cinnamon; starting the X11 session" >&2' \
    'exec dbus-launch --exit-with-session /usr/bin/cinnamon-session > /dev/null 2>&1' \
    > /defaults/startwm_wayland.sh && \
  chmod 0755 /defaults/startwm_wayland.sh && \
  echo "**** cleanup ****" && \
  apt-get autoclean && \
  rm -rf \
    /config/.cache \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /tmp/*
