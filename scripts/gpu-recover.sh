#!/usr/bin/env bash
# PANIC RECOVERY for single-GPU passthrough - reclaim the GPU to the host.
# Runs from SSH or the power button. Uses timeouts so it can't itself hang.
# If the GPU is truly wedged (QEMU stuck in D-state), NOTHING software can fix it -
# a hardware reset is the only cure and is SAFE (no vfio state persists to boot).
[ "${EUID:-$(id -u)}" -eq 0 ] || exec sudo -- "$0" "$@"
set -x
exec > >(tee -a /var/log/vfio-gpu.log) 2>&1

CONF=/etc/vfio-passthrough.conf
[ -r "$CONF" ] && . "$CONF"
: "${GPU_PCI:=0000:01:00.0}" "${GPU_AUDIO_PCI:=0000:01:00.1}" "${DISPLAY_MANAGER:=sddm}"
: "${USB_CTRL_PCI:=}" "${USB_CTRL_MATE_PCI:=}"
nodedev(){ echo "pci_${1//[:.]/_}"; }

echo "===== $(date -u) PANIC RECOVER ====="
logger -t gpu-recover "started - reclaiming GPU to host"

STOPPED=/run/gpu-stopped-units
ABORTED=/run/gpu-bind-aborted

restore_gpu_units() {
  if [ -s "$STOPPED" ]; then
    tac "$STOPPED" | while read -r u; do
      [ -n "$u" ] || continue
      case "$u" in
        "$DISPLAY_MANAGER"|"$DISPLAY_MANAGER".service) systemctl restart "$u" ;;
        *)                                             systemctl start "$u" ;;
      esac
    done
    rm -f "$STOPPED"
  else
    systemctl restart "$DISPLAY_MANAGER"
  fi
  rm -f "$ABORTED"
}

wedged=0
# 1) force-stop any -gpu VM (timeout-guarded - a D-state qemu won't die)
for vm in $(virsh -c qemu:///system list --name 2>/dev/null | grep -- '-gpu$'); do
  if timeout 20 virsh -c qemu:///system destroy "$vm" 2>/dev/null; then
    echo "destroyed $vm"; logger -t gpu-recover "destroyed VM $vm"
  elif virsh -c qemu:///system domstate "$vm" 2>/dev/null | grep -q running; then
    echo "!! $vm would not die within 20s (likely wedged GPU / D-state qemu)"; wedged=1
    logger -t gpu-recover "WEDGED: $vm would not die in 20s (D-state qemu?)"
  fi
done
sleep 3

# reclaim the USB controller from vfio first (if used), BEFORE modprobe -r vfio_pci
if [ -n "$USB_CTRL_PCI" ] && \
   [ "$(basename "$(readlink /sys/bus/pci/devices/$USB_CTRL_PCI/driver 2>/dev/null)" 2>/dev/null)" = "vfio-pci" ]; then
  echo "reclaiming USB controller from vfio"
  timeout 15 virsh -c qemu:///system nodedev-reattach "$(nodedev "$USB_CTRL_PCI")" 2>/dev/null
  [ -n "$USB_CTRL_MATE_PCI" ] && timeout 15 virsh -c qemu:///system nodedev-reattach "$(nodedev "$USB_CTRL_MATE_PCI")" 2>/dev/null
  echo "$USB_CTRL_PCI" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null
  echo '' > /sys/bus/pci/devices/$USB_CTRL_PCI/driver_override 2>/dev/null
  echo "$USB_CTRL_PCI" > /sys/bus/pci/drivers_probe 2>/dev/null
fi

# 2) force the card off vfio-pci if it's still there
for dev in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
  cur=$(basename "$(readlink /sys/bus/pci/devices/$dev/driver 2>/dev/null)" 2>/dev/null)
  [ "$cur" = "vfio-pci" ] && { echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind" 2>/dev/null; echo > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null; }
done

# 3) reload NVIDIA + re-probe
modprobe -r vfio_pci 2>/dev/null
modprobe -a nvidia nvidia_uvm nvidia_modeset 2>/dev/null; modprobe nvidia_drm modeset=1
for dev in "$GPU_PCI" "$GPU_AUDIO_PCI"; do echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null; done
sleep 1
for v in /sys/class/vtconsole/vtcon*/bind; do echo 1 > "$v" 2>/dev/null; done
restore_gpu_units

drv=$(basename "$(readlink /sys/bus/pci/devices/$GPU_PCI/driver 2>/dev/null)" 2>/dev/null)
echo "GPU now bound to: ${drv:-<none>} (want: nvidia)"
logger -t gpu-recover "GPU now on driver: ${drv:-none} (want nvidia)"
if [ "$wedged" = 1 ] || [ "$drv" != "nvidia" ]; then
  echo ">>> GPU appears WEDGED. Software recovery can't fix this state."
  echo ">>> Do a HARDWARE RESET - it is safe here (nothing vfio persists across boot)."
  logger -t gpu-recover "RECOVERY INCOMPLETE: GPU wedged/on '${drv:-none}' - HARDWARE RESET needed"
else
  logger -t gpu-recover "recovery OK: GPU back on nvidia, host services restored"
fi
echo "===== $(date -u) PANIC RECOVER done ====="
