#!/usr/bin/env bash
# Single-GPU passthrough: detach the NVIDIA GPU + its HDMI/DP audio from the host
# and bind them to vfio-pci. Runs as the libvirt 'prepare/begin' hook for the -gpu
# domain (see hooks/qemu), which passes the domain name as $1.
# FAIL-SAFE: if the GPU can't be cleanly released it ABORTS and restores the
# desktop rather than handing a half-held card to the VM (which wedges the GPU).
set -x
exec &>> /var/log/vfio-gpu.log
echo "===== $(date -u) BIND (GPU -> guest) ====="

GUEST="${1:-}"
CONF=/etc/vfio-passthrough.conf
[ -r "$CONF" ] && . "$CONF"
: "${GPU_PCI:=0000:01:00.0}" "${GPU_AUDIO_PCI:=0000:01:00.1}"
: "${DISPLAY_MANAGER:=sddm}" "${EXTRA_GPU_HOLDERS:=}"
: "${HOLDER_STOP_TIMEOUT:=8}" "${CLEAR_USER_TMP:=0}"
# whole seconds; 10# so a leading zero (08) is not read as octal
if [[ "$HOLDER_STOP_TIMEOUT" =~ ^[0-9]+$ ]]; then HOLDER_STOP_TIMEOUT=$((10#$HOLDER_STOP_TIMEOUT)); else HOLDER_STOP_TIMEOUT=8; fi
nodedev(){ echo "pci_${1//[:.]/_}"; }

STOPPED=/run/gpu-stopped-units
ABORTED=/run/gpu-bind-aborted
SESSION_USERS_FILE=/run/gpu-session-users
DOMAIN_XML=/run/gpu-domain.xml   # written by hooks/qemu from libvirt's stdin
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

# True if $1 is a regular user (uid >= 1000) whose systemd user manager is already
# running. Asked of the system manager on purpose: 'systemctl --user -M USER@' opens
# a PAM session for that user and would start their manager just to answer.
user_manager_up() {
  local uid
  uid=$(id -u "$1" 2>/dev/null) || return 1
  [ "$uid" -ge 1000 ] && systemctl is-active --quiet "user@$uid.service"
}

# Desktop users: anyone with an x11/wayland login session, plus anyone whose user
# manager still has graphical-session.target up (a session that outlived its login).
# Saved to $SESSION_USERS_FILE for the release hook and gpu-recover.sh.
desktop_users() {
  local sid u
  {
    for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
      [ "$(loginctl show-session "$sid" -p Class --value 2>/dev/null)" = user ] || continue
      case "$(loginctl show-session "$sid" -p Type --value 2>/dev/null)" in
        wayland|x11) loginctl show-session "$sid" -p Name --value 2>/dev/null ;;
      esac
    done
    for u in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}'); do
      user_manager_up "$u" || continue
      timeout 10 systemctl --user -M "$u@" is-active --quiet graphical-session.target 2>/dev/null && echo "$u"
    done
  } | while read -r u; do
    [ -n "$u" ] && [ "$(id -u "$u" 2>/dev/null || echo 0)" -ge 1000 ] && echo "$u"
  done | sort -u
}

# KDE Plasma 6 runs its compositor as a systemd --user unit, plasma-kwin_wayland,
# which is PartOf graphical-session.target. When the display manager stops, Plasma
# only stops plasma-workspace.target; graphical-session.target is left to stop by
# itself once no running unit needs it, and the DrKonqi crash-report launchers that
# pile up over a long session (Requisite=graphical-session.target) keep it up. So the
# compositor stays, holding the GPU. Killing it does not help: kwin_wayland_wrapper
# starts a new kwin_wayland at once (KWIN_RESTART_COUNT=1, 2...). A compositor left
# running also black-screens the NEXT login, because systemd thinks the new
# session's compositor is already up. So end the graphical session explicitly.
stop_graphical_sessions() {
  local u
  for u in $SESSION_USERS; do
    user_manager_up "$u" || continue
    echo "-- ending graphical session of $u"
    timeout 30 systemctl --user -M "$u@" stop graphical-session.target \
      || echo "!! could not stop graphical-session.target for $u"
    # Plasma's compositor unit; harmless "not loaded" error on other desktops
    timeout 30 systemctl --user -M "$u@" stop plasma-kwin_wayland.service 2>/dev/null
  done
  # -f: procps only matches the first 15 characters of a process name
  pkill -KILL -f '^([^ ]*/)?kwin_wayland_wrapper( |$)' 2>/dev/null && echo "-- killed leftover kwin_wayland_wrapper"
  pkill -KILL -x kwin_wayland 2>/dev/null && echo "-- killed leftover kwin_wayland"
  return 0
}

# Stop a GPU-holding service without letting a slow one stall the launch (Plex can
# sit in "deactivating" for its whole 90 s stop timeout): wait HOLDER_STOP_TIMEOUT
# seconds, then SIGKILL its cgroup. is-active is false while a unit is still
# deactivating, so check for a properly stopped state instead.
unit_stopped() {
  case "$(systemctl show -p ActiveState --value "$1" 2>/dev/null)" in inactive|failed) return 0 ;; esac
  return 1
}
stop_unit_fast() {
  local u="$1" i
  systemctl stop --no-block "$u"
  for ((i = 0; i < HOLDER_STOP_TIMEOUT; i++)); do unit_stopped "$u" && return 0; sleep 1; done
  echo "!! $u still stopping after ${HOLDER_STOP_TIMEOUT}s - SIGKILL"
  systemctl kill --signal=SIGKILL "$u"
  for ((i = 0; i < 5; i++)); do unit_stopped "$u" && return 0; sleep 1; done
  echo "!! $u still not stopped after SIGKILL"
}

stop_gpu_units() {
  : > "$STOPPED"
  local u ended=0
  while read -r u; do
    [ -n "$u" ] || continue
    if systemctl is-active --quiet "$u"; then
      echo "-- stopping GPU holder: $u"
      echo "$u" >> "$STOPPED"
      if [ "$u" = "$DISPLAY_MANAGER" ]; then
        systemctl stop "$u"
        stop_graphical_sessions; ended=1
      else
        stop_unit_fast "$u"
      fi
    fi
  done < <(gpu_units)
  # the display manager was already down: a graphical session may still be up
  [ "$ended" = 1 ] || stop_graphical_sessions
}

restore_gpu_units() {
  # the DM is still down here: clear any compositor that survived, or the next
  # login comes up black
  systemctl is-active --quiet "$DISPLAY_MANAGER" || stop_graphical_sessions
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

# OPTIONAL (CLEAR_USER_TMP=1). Where /tmp is a tmpfs, files there live in RAM (or in
# swap, which on a zram setup is RAM too). VFIO pins ALL of the guest's RAM up front,
# so a VM sized close to the host's RAM can be OOM-killed seconds after it starts if
# old temp files have eaten the headroom. A reboot would wipe /tmp anyway; this does
# the same for the desktop users' own top-level /tmp entries, except anything still
# needed. Kept: hidden entries, symlinks, mount points, folders holding sockets or
# fifos (tmux, ssh-agent), anything owned by another user or a service, anything a
# live process has open, mapped, or as its working or root directory (matched by
# inode, so containers and odd names count), anything a mount or loop device is
# backed by, and anything the domain XML points at. Every deletion is logged.
in_list() {        # $1 = entry, $2 = list; true if it, or anything below it, is listed
  P="$1" awk 'BEGIN { p = ENVIRON["P"] } $0 == p || index($0, p "/") == 1 { f = 1; exit } END { exit !f }' <<< "$2"
}
in_use() {         # $1 = entry; true if any inode under it is in $TMP_INUSE
  find "$1" -xdev -printf '%i\n' 2>/dev/null | grep -qxF -f <(printf '%s\n' "$TMP_INUSE")
}
unescape_mounts() { sed -e 's/\\040/ /g' -e 's/\\011/\t/g' -e 's/\\134/\\/g'; }
scan_timed_out() { echo "-- tmp-clean: in-use scan timed out (a hung mount?), nothing deleted"; set -x; }
clear_user_tmp() {
  [ "$CLEAR_USER_TMP" = 1 ] || return 0
  { set +x; } 2>/dev/null   # keep the big in-use lists out of the trace log
  if [ "$(stat -f -c %T /tmp 2>/dev/null)" != tmpfs ]; then
    echo "-- tmp-clean: /tmp is not a tmpfs, nothing to free"
    set -x; return 0
  fi
  local tdev tmaj tmin thex mounts fds dirs maps keep u uid e why kb total=0
  tdev=$(stat -c %d /tmp); tmaj=$(stat -c %Hd /tmp); tmin=$(stat -c %Ld /tmp)
  thex=$(printf '%02x:%02x' "$tmaj" "$tmin")
  # mount points at or below a /tmp entry, from the mount table, so nothing on a dead
  # network or FUSE mount is ever stat'ed
  mounts=$(awk '{ print $5 }' /proc/self/mountinfo | unescape_mounts | grep '^/tmp/')
  # inodes on /tmp's filesystem that live processes use, in any mount namespace. Each
  # scan is time-limited: a stat through a hung mount must not stall the launch.
  fds=$(timeout 30 find -L /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf '%D %i\n' 2>/dev/null)
  [ $? -eq 124 ] && { scan_timed_out; return 0; }
  dirs=$(timeout 30 find -L /proc/[0-9]*/cwd /proc/[0-9]*/root -maxdepth 0 -printf '%D %i\n' 2>/dev/null)
  [ $? -eq 124 ] && { scan_timed_out; return 0; }
  maps=$(timeout 30 awk -v h="$thex" '$4 == h && $5 != 0 { print $5 }' /proc/[0-9]*/maps 2>/dev/null)
  [ $? -eq 124 ] && { scan_timed_out; return 0; }
  TMP_INUSE=$( { printf '%s\n%s\n' "$fds" "$dirs" | awk -v d="$tdev" '$1 == d { print $2 }'; printf '%s\n' "$maps"; } )
  # paths that must stay: sources of mounts in any namespace (e.g. a folder bound into
  # a container), loop device backing files, and whatever the VM's XML mentions
  keep=$( { awk -v m="$tmaj:$tmin" '$3 == m && $4 != "/" { print "/tmp" $4 }' /proc/[0-9]*/mountinfo | unescape_mounts
            sed 's/ (deleted)$//' /sys/block/loop*/loop/backing_file
            grep -ohE "/tmp/[^'\"<>]+" "$DOMAIN_XML" "/etc/libvirt/qemu/$GUEST.xml"
          } 2>/dev/null | sort -u )
  for u in $SESSION_USERS; do
    uid=$(id -u "$u" 2>/dev/null) || continue
    for e in /tmp/*; do
      if in_list "$e" "$mounts"; then echo "-- tmp-clean: keeping (mount point) $e"; continue; fi
      [ -L "$e" ] && continue
      [ -d "$e" ] || [ -f "$e" ] || continue
      [ "$(stat -c %u "$e" 2>/dev/null)" = "$uid" ] || continue
      why=""
      if [ -d "$e" ] && [ -n "$(find "$e" -xdev \( -type s -o -type p -o -type b -o -type c \) -print -quit 2>/dev/null)" ]; then why="holds sockets or fifos"
      elif in_list "$e" "$keep"; then why="used by a mount, a loop device or this VM"
      elif in_use "$e"; then why="in use"
      fi
      if [ -n "$why" ]; then echo "-- tmp-clean: keeping ($why) $e"; continue; fi
      kb=$(du -sk --one-file-system -- "$e" 2>/dev/null | cut -f1)
      if rm -rf --one-file-system --preserve-root=all -- "$e"; then
        total=$(( total + ${kb:-0} )); echo "-- tmp-clean: deleted $e (${kb:-?} KiB)"
      fi
    done
  done
  echo "-- tmp-clean: freed about $(( total / 1024 )) MiB of RAM-backed /tmp"
  set -x
}

restore_and_abort() {
  echo "!! $1 - ABORTING passthrough, restoring host desktop"
  touch "$ABORTED"   # tells the release hook the card was NEVER detached
  modprobe -a nvidia nvidia_uvm nvidia_modeset 2>/dev/null; modprobe nvidia_drm modeset=1 2>/dev/null
  for v in /sys/class/vtconsole/vtcon*/bind; do echo 1 > "$v" 2>/dev/null; done
  restore_gpu_units
  exit 1   # non-zero => libvirt aborts the VM start
}

# 0) note who is logged in to the desktop, before it goes down
SESSION_USERS=$(desktop_users | tr '\n' ' ')
echo "$SESSION_USERS" > "$SESSION_USERS_FILE"
echo "-- desktop users: ${SESSION_USERS:-<none>}"

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

# 5b) the handover is going ahead: optionally free RAM held by old temp files
clear_user_tmp

# 6) clean release confirmed - hand the card to vfio-pci
modprobe vfio-pci
if ! virsh nodedev-detach "$(nodedev "$GPU_PCI")" || ! virsh nodedev-detach "$(nodedev "$GPU_AUDIO_PCI")"; then
  # undo a partial detach (e.g. the GPU went over but its audio function did not)
  # while nvidia is still unloaded; restore_and_abort's modprobe then rebinds it
  timeout 30 virsh nodedev-reattach "$(nodedev "$GPU_PCI")"
  timeout 30 virsh nodedev-reattach "$(nodedev "$GPU_AUDIO_PCI")"
  restore_and_abort "vfio bind failed"
fi

# CPU governor -> performance for the passthrough session (previous saved for restore)
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > /run/gpu-prev-governor 2>/dev/null
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null; done

echo "----- driver now bound: -----"
lspci -nnk -s "${GPU_PCI#0000:}" | grep -i 'in use'
echo "===== $(date -u) BIND done ====="
