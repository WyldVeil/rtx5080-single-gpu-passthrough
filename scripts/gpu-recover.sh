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
SESSION_USERS_FILE=/run/gpu-session-users

# True if $1 is a regular user (uid >= 1000) whose systemd user manager is already
# running. Asked of the system manager on purpose: 'systemctl --user -M USER@' opens
# a PAM session for that user and would start their manager just to answer.
user_manager_up() {
  local uid
  uid=$(id -u "$1" 2>/dev/null) || return 1
  [ "$uid" -ge 1000 ] && systemctl is-active --quiet "user@$uid.service"
}

# Desktop users the bind hook recorded. If there is no such record, anyone whose
# running user manager still has a graphical session or Plasma's compositor up.
session_users() {
  local u
  if [ -n "$(tr -d '[:space:]' < "$SESSION_USERS_FILE" 2>/dev/null)" ]; then cat "$SESSION_USERS_FILE"; return; fi
  for u in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}'); do
    user_manager_up "$u" || continue
    { timeout 10 systemctl --user -M "$u@" is-active --quiet graphical-session.target ||
      timeout 10 systemctl --user -M "$u@" is-active --quiet plasma-kwin_wayland.service; } 2>/dev/null && echo "$u"
  done
}

# A compositor left over from the session before the launch makes systemd skip
# starting a new one at the next login: black screen. Clear it before the display
# manager comes back. Only while the DM is down, so this can never end a session you
# have already logged back into.
stop_stale_graphical_sessions() {
  systemctl is-active --quiet "$DISPLAY_MANAGER" && return 0
  local u
  for u in $(session_users); do
    user_manager_up "$u" || continue
    echo "-- clearing any leftover graphical session of $u"
    timeout 30 systemctl --user -M "$u@" stop graphical-session.target \
      || echo "!! could not stop graphical-session.target for $u"
    timeout 30 systemctl --user -M "$u@" stop plasma-kwin_wayland.service 2>/dev/null
  done
  # -f: procps only matches the first 15 characters of a process name
  pkill -KILL -f '^([^ ]*/)?kwin_wayland_wrapper( |$)' 2>/dev/null && echo "-- killed leftover kwin_wayland_wrapper"
  pkill -KILL -x kwin_wayland 2>/dev/null && echo "-- killed leftover kwin_wayland"
  return 0
}

# Bring back everything vfio-gpu-bind.sh stopped. In a recovery the display manager
# may be up but broken, and a leftover compositor would black-screen the next login,
# so: take the DM down, clear the old session, restore the other units, DM last.
restore_gpu_units() {
  systemctl stop "$DISPLAY_MANAGER"
  stop_stale_graphical_sessions
  if [ -s "$STOPPED" ]; then
    tac "$STOPPED" | while read -r u; do
      [ -n "$u" ] || continue
      case "$u" in
        "$DISPLAY_MANAGER"|"$DISPLAY_MANAGER".service) ;;   # started last, below
        *) systemctl start "$u" ;;
      esac
    done
    rm -f "$STOPPED"
  fi
  systemctl start "$DISPLAY_MANAGER"
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
