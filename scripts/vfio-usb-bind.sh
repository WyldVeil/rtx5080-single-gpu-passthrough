#!/usr/bin/env bash
# OPTIONAL: hand the host's USB controller (and its IOMMU group-mate, if any) to a
# passthrough guest. If USB_CTRL_PCI is unset in /etc/vfio-passthrough.conf this is
# a no-op. Host loses USB on that controller until release - recovery is then SSH
# (network) or the power button (ACPI), not USB.
set -x
exec &>> /var/log/vfio-gpu.log

CONF=/etc/vfio-passthrough.conf
[ -r "$CONF" ] && . "$CONF"
: "${USB_CTRL_PCI:=}" "${USB_CTRL_MATE_PCI:=}"
nodedev(){ echo "pci_${1//[:.]/_}"; }

[ -n "$USB_CTRL_PCI" ] || { echo "(no USB_CTRL_PCI set - skipping USB passthrough)"; exit 0; }

echo "===== $(date -u) USB-BIND (controller -> guest) ====="
modprobe vfio-pci 2>/dev/null
[ -n "$USB_CTRL_MATE_PCI" ] && { virsh -c qemu:///system nodedev-detach "$(nodedev "$USB_CTRL_MATE_PCI")" 2>/dev/null || echo "!! detach mate failed (may be driverless-ok)"; }
virsh -c qemu:///system nodedev-detach "$(nodedev "$USB_CTRL_PCI")" 2>/dev/null || echo "!! detach $USB_CTRL_PCI failed"
drv=$(basename "$(readlink /sys/bus/pci/devices/$USB_CTRL_PCI/driver 2>/dev/null)" 2>/dev/null)
echo "USB $USB_CTRL_PCI now on: ${drv:-<none>} (want vfio-pci)"
echo "===== $(date -u) USB-BIND done ====="
