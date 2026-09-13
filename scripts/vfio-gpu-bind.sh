#!/usr/bin/env bash
# Single-GPU passthrough: detach the NVIDIA GPU + its HDMI/DP audio from the host
# and bind them to vfio-pci. Runs as the libvirt 'prepare/begin' hook for the -gpu
# domain (see hooks/qemu).
# FAIL-SAFE: if the GPU can't be cleanly released it ABORTS and restores the
# desktop rather than handing a half-held card to the VM (which wedges the GPU).
set -x
exec &>> /var/log/vfio-gpu.log
echo "===== $(date -u) BIND (GPU -> guest) ====="

CONF=/etc/vfio-passthrough.conf
[ -r "$CONF" ] && . "$CONF"
: "${GPU_PCI:=0000:01:00.0}" "${GPU_AUDIO_PCI:=0000:01:00.1}"
: "${DISPLAY_MANAGER:=sddm}" "${EXTRA_GPU_HOLDERS:=}"
nodedev(){ echo "pci_${1//[:.]/_}"; }

STOPPED=/run/gpu-stopped-units
ABORTED=/run/gpu-bind-aborted
rm -f "$ABORTED"          # clear any stale flag from a previous run

# Every service that can hold the GPU from OUTSIDE the desktop session, so stopping
# the display manager alone never releases them. DM first so the desktop goes down
# first; the restore path walks the list in reverse.
gpu_units() {
  printf '%s\n' "$DISPLAY_MANAGER" nvidia-persistenced
  for u in $EXTRA_GPU_HOLDERS; do printf '%s\n' "$u"; done
  systemctl list-units --no-legend --plain --state=active \
    'chrome-remote-desktop@*.service' 2>/dev/null | awk '{print $1}'
}

stop_gpu_units() {
  : > "$STOPPED"
  local u
  while read -r u; do
    [ -n "$u" ] || continue
    if systemctl is-active --quiet "$u"; then
      echo "-- stopping GPU holder: $u"
      echo "$u" >> "$STOPPED"
      systemctl stop "$u"
    fi
  done < <(gpu_units)
}

restore_gpu_units() {
  if [ -s "$STOPPED" ]; then
    tac "$STOPPED" | while read -r u; do
      [ -n "$u" ] && systemctl start "$u"
    done
    rm -f "$STOPPED"
  else
    systemctl start "$DISPLAY_MANAGER"
  fi
}

# Kill remaining GPU users. Deliberately NOT /dev/dri/card* - systemd (PID 1) and
# systemd-logind hold those, and SIGKILLing logind tears down seat management. The
# RENDER nodes are what a stray Xorg/compositor holds, and those pin nvidia_drm.
kill_gpu_holders() {
  fuser -k /dev/nvidia* /dev/dri/renderD* 2>/dev/null
}

restore_and_abort() {
  echo "!! $1 - ABORTING passthrough, restoring host desktop"
  touch "$ABORTED"   # tells the release hook the card was NEVER detached
  modprobe -a nvidia nvidia_uvm nvidia_modeset 2>/dev/null; modprobe nvidia_drm modeset=1 2>/dev/null
  for v in /sys/class/vtconsole/vtcon*/bind; do echo 1 > "$v" 2>/dev/null; done
  restore_gpu_units
  exit 1   # non-zero => libvirt aborts the VM start
}

# 1) stop every known GPU holder (desktop session + out-of-session services)
stop_gpu_units
sleep 2

# 2) release framebuffer/consoles
for v in /sys/class/vtconsole/vtcon*/bind; do echo 0 > "$v" 2>/dev/null; done
[ -e /sys/bus/platform/drivers/efi-framebuffer/unbind ] && \
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind 2>/dev/null

# 3) kill any process still holding the GPU nodes
kill_gpu_holders
sleep 1

# 4) unload the NVIDIA stack. Retry with backoff: GPU/UVM context teardown after a
#    SIGKILL is not instant, so a single attempt can lose a race it wins a moment later.
unloaded=0
for attempt in 1 2 3 4 5; do
  modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>/dev/null
  if ! lsmod | grep -q '^nvidia'; then unloaded=1; break; fi
  echo "-- unload attempt $attempt failed; modules still resident:"
  lsmod | grep '^nvidia'
  kill_gpu_holders
  sleep "$attempt"
done

# 5) VERIFY it actually let go - otherwise bail out safely
if [ "$unloaded" -ne 1 ]; then
  echo "-- processes still holding the GPU: --"
  fuser -v /dev/nvidia* /dev/dri/renderD* 2>&1
  restore_and_abort "nvidia modules still loaded (GPU busy: non-zero usage count)"
fi

# 6) clean release confirmed - hand the card to vfio-pci
modprobe vfio-pci
if ! virsh nodedev-detach "$(nodedev "$GPU_PCI")" || ! virsh nodedev-detach "$(nodedev "$GPU_AUDIO_PCI")"; then
  restore_and_abort "vfio bind failed"
fi

# CPU governor -> performance for the passthrough session (previous saved for restore)
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > /run/gpu-prev-governor 2>/dev/null
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null; done

echo "----- driver now bound: -----"
lspci -nnk -s "${GPU_PCI#0000:}" | grep -i 'in use'
echo "===== $(date -u) BIND done ====="
