#!/usr/bin/env bash
# Recover the HOST display after a post-passthrough "wedge": the host is alive
# (reachable over SSH) but the monitor is black after a -gpu VM shut down, because
# the GPU dropped its display link and will not re-assert it on its own.
# NOT a mains-drain case - run this over SSH:  sudo gpu-host-recover.sh
# Sequence: connector re-detect + display-manager restart + off/on cycle.
[ "${EUID:-$(id -u)}" -eq 0 ] || exec sudo -- "$0" "$@"
set -x
exec &>> /var/log/vfio-gpu.log

CONF=/etc/vfio-passthrough.conf
[ -r "$CONF" ] && . "$CONF"
: "${DISPLAY_MANAGER:=sddm}"

echo "===== $(date -u) HOST-DISPLAY-RECOVER ====="

# 1) force a hotplug re-detect on every DRM connector (revives the dropped link)
for s in /sys/class/drm/card*-*/status; do echo detect > "$s" 2>/dev/null; done
sleep 1

# 2) restart the display manager so X re-modesets onto the now-connected output
systemctl restart "$DISPLAY_MANAGER"
sleep 4

# 3) off->on cycle each CONNECTED connector to force the EDID/link re-read
for st in /sys/class/drm/card*-*/status; do
  [ "$(cat "$st" 2>/dev/null)" = connected ] || continue
  echo off    > "$st" 2>/dev/null; sleep 1
  echo detect > "$st" 2>/dev/null
done
sleep 2

echo "----- connectors after recover: -----"
for c in /sys/class/drm/card*-*; do [ -e "$c/status" ] && echo "$(basename "$c"): $(cat "$c/status")"; done
echo "===== $(date -u) HOST-DISPLAY-RECOVER done - check the monitor ====="
