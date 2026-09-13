#!/usr/bin/env bash
# Install the single-GPU passthrough scripts, libvirt hook, ACPI escape hatch and
# the config file. Run from the repo root:  sudo ./scripts/install.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

install -Dm755 "$HERE/vfio-gpu-bind.sh"     /usr/local/bin/vfio-gpu-bind.sh
install -Dm755 "$HERE/vfio-gpu-release.sh"  /usr/local/bin/vfio-gpu-release.sh
install -Dm755 "$HERE/vfio-usb-bind.sh"     /usr/local/bin/vfio-usb-bind.sh
install -Dm755 "$HERE/vfio-usb-release.sh"  /usr/local/bin/vfio-usb-release.sh
install -Dm755 "$HERE/gpu-host-recover.sh"  /usr/local/bin/gpu-host-recover.sh
install -Dm755 "$HERE/gpu-recover.sh"       /usr/local/bin/gpu-recover.sh
install -Dm755 "$HERE/hooks/qemu"           /etc/libvirt/hooks/qemu
chmod +x /etc/libvirt/hooks/qemu

# config: never clobber an existing one
if [ ! -e /etc/vfio-passthrough.conf ]; then
  install -Dm644 "$REPO/examples/passthrough.conf.example" /etc/vfio-passthrough.conf
  echo ">> installed /etc/vfio-passthrough.conf - EDIT IT for your GPU before first use"
else
  echo ">> /etc/vfio-passthrough.conf already exists - left untouched"
fi

# optional ACPI power-button escape hatch (needs acpid)
if command -v acpid >/dev/null 2>&1; then
  install -Dm755 "$HERE/acpi/gpu-power-action.sh" /etc/acpi/gpu-power-action.sh
  install -Dm644 "$HERE/acpi/gpu-powerbtn.event"  /etc/acpi/events/gpu-powerbtn
  install -Dm644 /dev/stdin /etc/systemd/logind.conf.d/10-gpu-powerbtn.conf <<'EOF'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=poweroff
EOF
  systemctl enable --now acpid 2>/dev/null || true
  systemctl restart acpid 2>/dev/null || true
  echo ">> ACPI power-button recovery installed (re-login or reboot for the logind change)"
else
  echo ">> acpid not installed - skipping the power-button escape hatch (optional but recommended)"
fi

# reload libvirt so the hook is picked up
systemctl restart libvirtd 2>/dev/null || systemctl restart virtqemud 2>/dev/null || true

cat <<'NEXT'

>> Installed. Next steps:
   1) Edit /etc/vfio-passthrough.conf  (set GPU_PCI / GPU_AUDIO_PCI, and optionally
      EXTRA_GPU_HOLDERS and USB_CTRL_PCI). Find IDs: lspci -Dnn | grep -Ei 'vga|3d|audio'
   2) Make sure IOMMU is enabled on the kernel cmdline - see docs/02-host-setup.md
   3) Name your passthrough VM so its domain name ends in -gpu (e.g. win11-gpu)
   4) Add <rom bar='off'/> to the GPU hostdev - see examples/domain-gpu.xml
   5) Manual recovery any time (over SSH):  sudo gpu-host-recover.sh
NEXT
