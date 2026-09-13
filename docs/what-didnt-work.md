# What did not work (so you don't repeat it)

RTX 50 / Blackwell single-GPU passthrough is full of plausible-sounding fixes that
waste days. Here is what we actually ruled out, and why, on a real RTX 5080.

## Black guest screen

- **Passing a captured VBIOS as `<rom file=...>`.** The classic "tainted primary
  VBIOS" fix. We captured a byte-perfect clean VBIOS (correct version, valid
  checksums, both the legacy and EFI-GOP images) and it loaded fine. Still black.
  A romfile also forces the ROM BAR *on*, which is the opposite of the fix.
- **The NVIDIA vBIOS VFIO patcher.** It trims the ROM down to the legacy x86 image
  and strips the EFI GOP - the exact part a UEFI/OVMF guest wants. Wrong tool for a
  UEFI guest.
- **`nvidia_drm.modeset=1` inside the guest as "the fix".** Worth having, and the
  EndeavourOS NVIDIA ISO entry already sets it, but it did not fix the black screen
  on its own. Proven: with modeset on but the ROM BAR at default, still black.
- **HDMI vs DisplayPort.** Black on both.
- **Disabling Resizable BAR / toggling Above-4G in firmware.** No effect on the
  display problem.
- **A guest-side re-plug / connector kick script.** Fragile and timing-dependent;
  never reliable. Not needed once `rombar off` is in place.

What did work: **`<rom bar='off'/>`** on the GPU hostdev. Full stop.

## Black host screen after guest shutdown

- **Warm reboot.** The card holds the dropped-link state across it, even though it
  is the boot VGA and gets re-POSTed. Only removing power cleared it... until we
  found the software revive.
- **`systemctl suspend` + wake (deep S3).** On a desktop board that keeps the PCIe
  slot powered through S3, the GPU never power-cycles, so this does not recover it.
  If your board actually cuts slot power in S3, it might work for you.
- **An FLR / bus reset in the handback.** A warm reboot already does a full bus
  reset and did not help, so a targeted reset does not either.

What did work: a **software hotplug** - re-detect the DRM connectors
(`echo detect > /sys/class/drm/card*-*/status`), restart the display manager, then
off/on cycle the connected connector. The card re-asserts the link and the desktop
comes back. This is automated in `vfio-gpu-release.sh` and `gpu-host-recover.sh`.

## Notes that saved us time

- On the host the GPU may be `card0` or `card1` depending on whether an iGPU is
  enumerated. The scripts glob `card*-*` so they don't care.
- `sysfs` can report a connector as `enabled=disabled` with no EDID even while the
  display manager is happily driving it. Trust the monitor, not sysfs.
- The `no target node available` line QEMU prints on the hostdev is usually a
  PipeWire audio red herring, not a romfile failure.
- The only guaranteed way to remove the black-screen window entirely is a second GPU
  for the host (dual-GPU), so the host never has to re-init the passed card. With
  the fixes here, single-GPU is usable without it.
