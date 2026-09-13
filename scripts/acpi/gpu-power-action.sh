#!/usr/bin/env bash
# acpid power-button handler - emergency escape hatch for single-GPU passthrough.
# If a *-gpu VM is running (desktop torn down), reclaim the GPU. During normal
# desktop use, do nothing and let your DE handle the button as usual.

# debounce - acpid delivers this event twice (netlink + input layer)
LOCK=/run/gpu-powerbtn.lock
now=$(date +%s)
if [ -f "$LOCK" ] && [ $(( now - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) )) -lt 5 ]; then exit 0; fi
touch "$LOCK"

# test mode: `sudo touch /etc/acpi/POWERBTN_TEST` makes the button log only
if [ -f /etc/acpi/POWERBTN_TEST ]; then
  logger -t gpu-powerbtn "TEST: power button received by acpid (no action taken)"
  exit 0
fi

for vm in $(virsh -c qemu:///system list --name 2>/dev/null | grep -- '-gpu$'); do
  logger -t gpu-powerbtn "power button: $vm running -> GPU recovery"
  exec /usr/local/bin/gpu-recover.sh
done
logger -t gpu-powerbtn "power button: no GPU VM -> deferring to desktop"
exit 0
