#!/usr/bin/env bash
# Single-GPU passthrough: return the GPU + audio to the host and bring the desktop
# back. libvirt 'release/end' hook for the -gpu domain; also safe to run by hand.
# SELF-HEALING: force-rebinds nvidia if nodedev-reattach leaves the card unbound,
# AND revives a dropped display link (the "black host after guest shutdown" wedge).
set -x
exec &>> /var/log/vfio-gpu.log
echo "===== $(date -u) RELEASE (GPU -> host) ====="

CONF=/etc/vfio-passthrough.conf
[ -r "$CONF" ] && . "$CONF"
: "${GPU_PCI:=0000:01:00.0}" "${GPU_AUDIO_PCI:=0000:01:00.1}" "${DISPLAY_MANAGER:=sddm}"
nodedev(){ echo "pci_${1//[:.]/_}"; }

STOPPED=/run/gpu-stopped-units
ABORTED=/run/gpu-bind-aborted

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

# If the bind hook ABORTED, the GPU was never handed to vfio-pci and the desktop is
# already back. Do not touch the PCI device - just confirm state and clear the flag.
if [ -e "$ABORTED" ]; then
  echo "-- bind aborted earlier: GPU was never detached, skipping reattach/self-heal --"
  modprobe -a nvidia nvidia_uvm nvidia_modeset 2>/dev/null; modprobe nvidia_drm modeset=1 2>/dev/null
  for v in /sys/class/vtconsole/vtcon*/bind; do echo 1 > "$v" 2>/dev/null; done
  restore_gpu_units
  rm -f "$ABORTED"
  echo "===== $(date -u) RELEASE skipped (bind abort) ====="
  exit 0
fi

modprobe -a nvidia nvidia_uvm nvidia_modeset 2>/dev/null; modprobe nvidia_drm modeset=1 2>/dev/null
sleep 1

# normal path: hand the devices back to their host driver (timeout-guarded)
timeout 30 virsh nodedev-reattach "$(nodedev "$GPU_PCI")"       || echo "!! reattach $GPU_PCI timed out/failed"
timeout 30 virsh nodedev-reattach "$(nodedev "$GPU_AUDIO_PCI")" || echo "!! reattach $GPU_AUDIO_PCI timed out/failed"
sleep 1

# self-heal 1: if the GPU didn't actually land on nvidia, force it
drv=$(basename "$(readlink /sys/bus/pci/devices/$GPU_PCI/driver 2>/dev/null)" 2>/dev/null)
if [ "$drv" != "nvidia" ]; then
  echo "GPU on '${drv:-none}' after reattach - forcing nvidia rebind"
  for d in "$GPU_PCI" "$GPU_AUDIO_PCI"; do echo '' > "/sys/bus/pci/devices/$d/driver_override" 2>/dev/null; done
  modprobe -r vfio_pci vfio_pci_core vfio_iommu_type1 vfio 2>/dev/null
  modprobe -a nvidia nvidia_uvm nvidia_modeset 2>/dev/null; modprobe nvidia_drm modeset=1 2>/dev/null
  for d in "$GPU_PCI" "$GPU_AUDIO_PCI"; do echo "$d" > /sys/bus/pci/drivers_probe 2>/dev/null; done
  sleep 2
  drv=$(basename "$(readlink /sys/bus/pci/devices/$GPU_PCI/driver 2>/dev/null)" 2>/dev/null)
fi

# reclaim consoles/framebuffer
for v in /sys/class/vtconsole/vtcon*/bind; do echo 1 > "$v" 2>/dev/null; done
[ -e /sys/bus/platform/drivers/efi-framebuffer/bind ] && \
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/bind 2>/dev/null

echo "----- GPU now bound to: ${drv:-<none>} (want: nvidia) -----"
# restore CPU governor to what it was before passthrough
prev=$(cat /run/gpu-prev-governor 2>/dev/null || echo powersave)
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$prev" > "$g" 2>/dev/null; done
restore_gpu_units

# --- self-heal 2: revive a dropped display link (the post-passthrough wedge) ------
# After a driven-display teardown an NVIDIA card (seen on RTX 50 / Blackwell) often
# drops its DRM connectors to 'disconnected' and will not re-assert HPD, so nvidia
# rebinds and the DM restarts but the monitor stays black. This survives a warm
# reboot; only power removal - OR this software hotplug - brings it back. We ONLY
# act when NO connector is connected, so clean shutdowns are left untouched.
sleep 4
_any=0
for _st in /sys/class/drm/card*-*/status; do [ "$(cat "$_st" 2>/dev/null)" = connected ] && _any=1; done
if [ "$_any" = 0 ]; then
  echo "-- no connected display after handback (wedge) -> reviving display link"
  for _s in /sys/class/drm/card*-*/status; do echo detect > "$_s" 2>/dev/null; done
  sleep 1
  systemctl restart "$DISPLAY_MANAGER"
  sleep 4
  for _st in /sys/class/drm/card*-*/status; do
    [ "$(cat "$_st" 2>/dev/null)" = connected ] || continue
    echo off > "$_st" 2>/dev/null; sleep 1; echo detect > "$_st" 2>/dev/null
  done
  echo "-- display-link revive attempted; connectors now:"
  for _c in /sys/class/drm/card*-*; do [ -e "$_c/status" ] && echo "   $(basename "$_c"): $(cat "$_c/status")"; done
fi
# ---------------------------------------------------------------------------------
echo "===== $(date -u) RELEASE done ====="
