#!/usr/bin/env bash
# OPTIONAL: return the USB controller to the host. No-op if USB_CTRL_PCI is unset.
# Self-heals if reattach leaves it unbound.
set -x
exec &>> /var/log/vfio-gpu.log

CONF=/etc/vfio-passthrough.conf
[ -r "$CONF" ] && . "$CONF"
: "${USB_CTRL_PCI:=}" "${USB_CTRL_MATE_PCI:=}"
nodedev(){ echo "pci_${1//[:.]/_}"; }

[ -n "$USB_CTRL_PCI" ] || { echo "(no USB_CTRL_PCI set - skipping USB release)"; exit 0; }

echo "===== $(date -u) USB-RELEASE (controller -> host) ====="
timeout 20 virsh -c qemu:///system nodedev-reattach "$(nodedev "$USB_CTRL_PCI")" 2>/dev/null
[ -n "$USB_CTRL_MATE_PCI" ] && timeout 20 virsh -c qemu:///system nodedev-reattach "$(nodedev "$USB_CTRL_MATE_PCI")" 2>/dev/null
sleep 1
drv=$(basename "$(readlink /sys/bus/pci/devices/$USB_CTRL_PCI/driver 2>/dev/null)" 2>/dev/null)
if [ "$drv" != "xhci_hcd" ]; then
  echo "USB on '${drv:-none}' after reattach - forcing xhci rebind"
  echo "$USB_CTRL_PCI" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null
  echo '' > /sys/bus/pci/devices/$USB_CTRL_PCI/driver_override 2>/dev/null
  echo "$USB_CTRL_PCI" > /sys/bus/pci/drivers_probe 2>/dev/null
  sleep 1
  drv=$(basename "$(readlink /sys/bus/pci/devices/$USB_CTRL_PCI/driver 2>/dev/null)" 2>/dev/null)
fi
echo "USB $USB_CTRL_PCI now on: ${drv:-<none>} (want xhci_hcd)"
echo "===== $(date -u) USB-RELEASE done ====="
