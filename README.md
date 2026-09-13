# RTX 50 series (Blackwell) single-GPU passthrough on Linux

Everything needed to pass an RTX 50-series GPU to a VM on a machine that has only
that one GPU, and to get back to your desktop cleanly afterwards. This is the
result of a long, stubborn debugging session, so it documents the dead ends too.

It solves two problems that the usual guides do not:

1. **The guest boots but the display stays black** once the NVIDIA driver loads.
   The fix on Blackwell is `<rom bar='off'/>` on the GPU hostdev. Not a romfile,
   not a VBIOS patch. See [The fix for the black guest screen](#the-fix-for-the-black-guest-screen).
2. **The host comes back to a black screen after the guest shuts down**, and it
   survives a warm reboot (only pulling power fixes it). This is a *dropped display
   link*, not a fatal reset bug, and it can be revived purely in software. The
   handback self-heals automatically. See [The black host screen after shutdown](#the-black-host-screen-after-shutdown).

> **It even works on the EndeavourOS live ISO, not just an installed system.** With
> the ISO patcher and `rombar off` in place, you can boot the live EndeavourOS
> environment as a single-GPU passthrough guest and have the real card drive your
> monitor, before installing anything at all. Getting a live distro to run under
> single-GPU passthrough with working NVIDIA output has never been easy, and people
> have struggled with it for years. Here it is boot-and-go: point the VM at the
> patched ISO, launch it, and the live desktop comes up on the passed-through GPU.
> That makes it perfect for trying, testing, or troubleshooting with a full GPU
> before you commit to an install.

## Tested on

- RTX 5080 (GB203, `10de:2c02`), single GPU, monitor on DisplayPort
- Host: Arch Linux, libvirt + QEMU, OVMF/UEFI guest (q35)
- Guest: EndeavourOS live/installed, and Windows
- The GPU is the primary/boot VGA (`boot_vga=1`)

## Should also work on

This was tested on an RTX 5080, but nothing here is 5080-specific. Everything is
config-driven (you set your own PCI address), so in theory it should work on:

- **Any RTX 50-series card** - the whole Blackwell lineup (5090, 5080, 5070 Ti,
  5070, 5060 and so on). They share the display-init and reset behaviour we hit, so
  `rombar off` and the connector-revive handback should apply directly.
- **Other NVIDIA cards with the same symptoms.** If you get a black guest screen on
  single-GPU passthrough, or a black host screen after the VM shuts down that only a
  power drain clears, the two fixes here are worth trying whatever the generation.

## How it works

A libvirt hook fires whenever a domain whose name ends in `-gpu` starts or stops:

- **On start:** stop the display manager and any other GPU holders, unload nvidia,
  bind the card to `vfio-pci`, hand it to the VM. If it cannot cleanly release the
  card it aborts and restores the desktop instead of half-handing a wedged GPU.
- **On stop:** rebind nvidia, restart the display manager, and - if the card came
  back with its display link dropped - revive it automatically.

Everything reads one config file, `/etc/vfio-passthrough.conf`.

## Prerequisites

- IOMMU enabled in firmware (VT-d / AMD-Vi) and on the kernel cmdline:
  - Intel: `intel_iommu=on`
  - AMD: `amd_iommu=on`
- `vfio-pci` available (in-tree on modern kernels).
- Packages: `libvirt qemu-full edk2-ovmf` and, for the ISO patcher and recovery,
  standard `util-linux`. Optional: `acpid` for the power-button escape hatch.
- The NVIDIA GPU and its HDMI/DP audio function in a **clean IOMMU group**. Check:
  ```bash
  for g in /sys/kernel/iommu_groups/*; do echo "group ${g##*/}: $(ls $g/devices)"; done
  ```
- **RTX 50 / Blackwell needs the open kernel modules** (`nvidia-open` / dkms-open),
  both on the host and in the guest. The proprietary module cannot init Blackwell.
- An SSH lifeline is recommended (single-GPU means the host goes headless
  while the VM runs). Enable `sshd` and allow it on your LAN.

## Setup

### 1. Install the scripts

```bash
git clone https://github.com/WyldVeil/rtx5080-single-gpu-passthrough
cd rtx5080-single-gpu-passthrough
sudo ./scripts/install.sh
```

Then edit the config for your card:

```bash
sudo nano /etc/vfio-passthrough.conf     # set GPU_PCI / GPU_AUDIO_PCI, etc.
```

Find the addresses with `lspci -Dnn | grep -Ei 'vga|3d|audio'`.

### 2. Patch the EndeavourOS ISO (EndeavourOS guests only)

In single-GPU passthrough there is no emulated display, so the ISO's boot menu is
invisible until the real GPU's driver comes up. If the default entry is nouveau,
Blackwell shows nothing. This remasters a copy so it auto-selects the NVIDIA entry
with a 1-second timeout:

```bash
sudo ./scripts/patch-eos-iso.sh ~/Downloads/EndeavourOS.iso
# -> writes EndeavourOS_gpu.iso next to it; point the VM's CDROM at that
```

(For a Windows guest, skip this - install the NVIDIA driver first, see below.)

### 3. Create the VM

Build a normal **UEFI (q35, OVMF)** VM in virt-manager, install the OS, then add
the GPU passthrough bits. The one that matters:

```xml
<hostdev mode='subsystem' type='pci' managed='no'>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>  <!-- your GPU -->
  </source>
  <rom bar='off'/>
</hostdev>
```

See [`examples/domain-gpu.xml`](examples/domain-gpu.xml) for the full template.
**The domain name must end in `-gpu`** so the hook fires.

Install the guest NVIDIA driver **before** relying on the passthrough display
(a guest with no driver = black screen with no recovery except the host tools here).

### 4. Launch

Start the domain (`virsh start <name>-gpu`, a desktop shortcut, etc.). The desktop
tears down, the monitor switches to the VM once the guest driver loads, and your
desktop returns when the VM shuts down.

## The fix for the black guest screen

Symptom: OVMF/boot shows, then black the moment the guest driver takes over. The
GPU is passed through fine, it just will not put an image out.

The fix is **`<rom bar='off'/>`** on the GPU hostdev. With the ROM BAR exposed to
the guest (the default, and what a `<rom file=...>` forces), the guest firmware
trips over the option ROM and never brings the display up on Blackwell. With it
off, OVMF skips the ROM and the NVIDIA driver initialises the display itself.

Do **not** use a captured VBIOS romfile - see [what did not work](docs/what-didnt-work.md).

## The black host screen after shutdown

Symptom: guest shuts down, nvidia rebinds and the login manager restarts (logs say
success), but the monitor is black. A warm reboot does not fix it; only removing
power does.

Cause: the card drops its DRM connectors to `disconnected` and will not re-assert
the display link on its own. It is recoverable in software:

- **Automatic:** the release hook detects "no connected display after handback" and
  re-detects the connectors + restarts the display manager + cycles the link. So a
  normal guest shutdown brings the desktop back on its own.
- **Manual, if it ever misses** (over SSH):
  ```bash
  sudo gpu-host-recover.sh
  ```

Note: `systemctl suspend` (deep S3) does **not** help on a desktop board that keeps
the PCIe slot powered in S3 - the GPU never power-cycles. The connector re-detect is
what actually works.

## Recovery reference

If the VM crashes, or the desktop does not come back after the VM shuts down, here
are the ways to recover, gentlest first.

| Situation | What to do |
| --- | --- |
| Host black after a normal guest shutdown | over SSH: `sudo gpu-host-recover.sh` |
| VM crashed / stuck, or the desktop did not hand back | **one short press of the power button (do not hold)** - or over SSH: `sudo gpu-recover.sh` |
| GPU truly wedged, nothing responds at all | full power cycle (see below) |

**The power button is your no-SSH escape hatch.** While a `-gpu` VM is running (so the
desktop is torn down), a single short press runs `gpu-recover.sh`, which force-stops
the VM and hands the GPU back to the host. Press it once and wait a few seconds - do
not hold it, because a long hold is set to force a hard poweroff. During normal
desktop use the button behaves as usual (your desktop environment handles it).

Logs for both: `/var/log/vfio-gpu.log`, and `journalctl -t gpu-recover -t gpu-powerbtn`.

### Full power cycle (last resort)

Only if the GPU is truly wedged - `gpu-recover.sh` says so, or nothing responds at
all. A warm reboot is often not enough, because an NVIDIA card can hold the bad state
across it. Shut the machine down, switch the PSU off at the back (or pull the plug),
hold the case power button for 20 to 30 seconds to drain residual charge, then power
the PSU back on and boot. This is safe here, because nothing the vfio scripts set up
persists across a boot.

## Repo layout

```
scripts/
  install.sh            install everything + the config
  patch-eos-iso.sh      remaster EndeavourOS ISO to auto-boot the NVIDIA entry (1s)
  vfio-gpu-bind.sh      hand the GPU to the guest (fail-safe)
  vfio-gpu-release.sh   return the GPU + self-heal the display link
  vfio-usb-bind.sh      optional: hand a USB controller to the guest
  vfio-usb-release.sh   optional: return the USB controller
  gpu-host-recover.sh   manual host-display recovery
  gpu-recover.sh        panic reclaim (SSH or power button)
  hooks/qemu            libvirt hook (fires for *-gpu domains)
  acpi/                 power-button escape hatch
examples/
  domain-gpu.xml            VM template with rombar off
  passthrough.conf.example  the config file
docs/
  what-didnt-work.md        the dead ends, so you don't repeat them
```

## Credits

Written up by WyldVeil after solving this the hard way. Shared so the next person
with a black screen on RTX 50 single-GPU passthrough does not lose a week to it.
MIT licensed - use it, fork it, improve it.
