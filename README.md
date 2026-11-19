# RTX 50 series (Blackwell) single-GPU passthrough on Linux

Everything needed to pass an RTX 50-series GPU to a VM on a machine that has only
that one GPU, and to get back to your desktop cleanly afterwards. This is the
result of a long, stubborn debugging session, so it documents the dead ends too.

It solves three problems that the usual guides do not:

1. **The guest boots but the display stays black** once the NVIDIA driver loads.
   The fix on Blackwell is `<rom bar='off'/>` on the GPU hostdev. Not a romfile,
   not a VBIOS patch. See [The fix for the black guest screen](#the-fix-for-the-black-guest-screen).
2. **The host comes back to a black screen after the guest shuts down**, and it
   survives a warm reboot (only pulling power fixes it). This is a *dropped display
   link*, not a fatal reset bug, and it can be revived purely in software. The
   handback self-heals automatically. See [The black host screen after shutdown](#the-black-host-screen-after-shutdown).
3. **Launching again without a reboot fails.** The first launch works, a later one
   ends on a black screen, and a reboot (or a power drain) looks like the only cure.
   On KDE Plasma 6 the old desktop session can outlive the login screen and keep
   hold of the GPU. The hooks now end it themselves. See [Launching again without a reboot](#launching-again-without-a-reboot).

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
- Desktop: KDE Plasma 6 (Wayland) with SDDM
- The GPU is the primary/boot VGA (`boot_vga=1`)

## Should also work on

This was tested on an RTX 5080, but nothing here is 5080-specific. Everything is
config-driven (you set your own PCI address), so in theory it should work on:

- **Any RTX 50-series card** - the whole Blackwell lineup (5090, 5080, 5070 Ti,
  5070, 5060 and so on). They share the display-init and reset behaviour we hit, so
  `rombar off` and the connector-revive handback should apply directly.
- **Other NVIDIA cards with the same symptoms.** If you get a black guest screen on
  single-GPU passthrough, or a black host screen after the VM shuts down that only a
  power drain clears, the first two fixes here are worth trying whatever the generation.

## How it works

A libvirt hook fires whenever a domain whose name ends in `-gpu` starts or stops:

- **On start:** stop the display manager, end the desktop session (including its
  systemd user units, so the compositor cannot come back), stop any other GPU
  holders (each gets a few seconds to stop before it is killed), unload nvidia, bind
  the card to `vfio-pci`, hand it to the VM. If it cannot cleanly release the card it
  restores the desktop and fails the VM start instead of half-handing a wedged GPU.
- **On stop:** rebind nvidia, make sure nothing from the old desktop session is still
  running, restart the display manager, and, if the card came back with its display
  link dropped, revive it automatically.

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

Two optional settings are worth a look: `HOLDER_STOP_TIMEOUT` (how long services
like Plex get to stop before they are killed, default 8 seconds) and
`CLEAR_USER_TMP` (see [The VM dies a few seconds after it starts](#the-vm-dies-a-few-seconds-after-it-starts)).

**Updating from 1.0:** `git pull`, then run `sudo ./scripts/install.sh` again. Your
config is left as it is, and the new settings fall back to safe defaults. The
scripts in `/usr/local/bin` and the hook at `/etc/libvirt/hooks/qemu` are replaced;
if you had changed any of them, your copy is kept next to it with a `.bak-` suffix.

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

## Launching again without a reboot

Two separate problems, and both look like "it only works after a reboot".

### The handover fails: black screen, or black after logging back in

Symptom: the first launch works. A later one ends on a black screen, or throws you
back to the login screen, and logging in from there gives a black screen.
`/var/log/vfio-gpu.log` shows `unload attempt 1 failed` through `5`, then
`ABORTING passthrough`, with `kwin_wayland` as the process still holding the GPU.

Cause: when the display manager stops, Plasma stops `plasma-workspace.target` but
not `graphical-session.target`. That one is left to stop by itself once no running
unit needs it, and the compositor (`plasma-kwin_wayland.service`) is part of it, so
the compositor stays up too. On the test machine the units still needing it were
DrKonqi crash-report launchers (`drkonqi-coredump-launcher@...`), one for each
program that crashed. They pile up over a long session, which fits the failures only
showing up after one. `systemctl --user list-dependencies --reverse graphical-session.target`
shows what is holding yours. With the compositor up, nvidia will not unload and the
hook aborts. Killing the compositor does not help, because `kwin_wayland_wrapper`
starts a fresh `kwin_wayland` straight away. The journal counts them:
`KWIN_RESTART_COUNT=1`, `2`, `3`. The leftover compositor then causes the second
black screen. When you log in again, systemd thinks the new session's compositor is
already running and never starts one.

Fix, automatic since 1.1: the bind hook ends every desktop user's
`graphical-session.target` itself and kills `kwin_wayland_wrapper`, and both hooks
clear any leftover session before the display manager starts again. If you are ever
stuck at a black screen after logging in, `sudo gpu-recover.sh` over SSH does the
same cleanup and brings the login screen back.

Related: the other services that can hold the GPU (`nvidia-persistenced`, Chrome
Remote Desktop and anything in `EXTRA_GPU_HOLDERS`) now get `HOLDER_STOP_TIMEOUT`
seconds to stop, and are killed if they are still running after that. Plex could
otherwise take 90 seconds, and the launch looks dead while it waits.

### The VM dies a few seconds after it starts

Symptom: the handover works and the VM starts, but within half a minute the desktop
comes back by itself. The libvirt log (`/var/log/libvirt/qemu/<name>.log`) ends with
`shutting down, reason=failed`, and the kernel log shows the OOM killer taking
`qemu-system-x86`:

```bash
journalctl -k -b | grep -iE 'oom|out of memory'
```

Cause: the host ran out of memory. With VFIO all of the guest's RAM is pinned from
the start, so the host keeps only what is left over. Where `/tmp` is a tmpfs, the
files in it live in RAM too, or in swap, which on a zram setup is RAM again. A few GB
of old build output in there is enough. Here it was a 56 GiB guest on a 64 GB host
with 15 GB sitting in `/tmp`. `df -h /tmp` shows what you are carrying.

Fix: set `CLEAR_USER_TMP=1` in `/etc/vfio-passthrough.conf`. Once the desktop is down
and the handover is going ahead, the bind hook does to your own files what a reboot
does to a RAM-backed `/tmp`: it deletes everything of yours at the top of `/tmp`
that nothing still needs. It keeps hidden entries, mount points, folders holding
sockets or fifos (tmux, ssh-agent), anything a running process has open, mapped or
is working in (containers included), anything a mount or loop device uses, anything
the VM's own XML points at, and anything owned by another user or a service. Every
deletion is listed in `/var/log/vfio-gpu.log`. It is off by default because it
deletes files, so keep nothing in `/tmp` that you want to keep.

## Recovery reference

If a launch fails, the VM crashes, or the desktop does not come back after the VM
shuts down, here are the ways to recover, gentlest first.

| Situation | What to do |
| --- | --- |
| Host black after a normal guest shutdown | over SSH: `sudo gpu-host-recover.sh` |
| VM crashed / stuck, or the desktop did not hand back | **one short press of the power button (do not hold)** - or over SSH: `sudo gpu-recover.sh` |
| Launch failed, you are back at the login screen, and logging in gives a black screen | over SSH: `sudo gpu-recover.sh` (ends the leftover session, restarts the login screen) |
| VM dies within seconds and the desktop comes back by itself | out of memory, see [The VM dies a few seconds after it starts](#the-vm-dies-a-few-seconds-after-it-starts) |
| GPU truly wedged, nothing responds at all | full power cycle (see below) |

**The power button is your no-SSH escape hatch.** While a `-gpu` VM is running (so the
desktop is torn down), a single short press runs `gpu-recover.sh`, which force-stops
the VM and hands the GPU back to the host. Press it once and wait a few seconds - do
not hold it, because a long hold is set to force a hard poweroff. During normal
desktop use the button behaves as usual (your desktop environment handles it).

Logs for both: `/var/log/vfio-gpu.log`, and `journalctl -t gpu-recover -t gpu-powerbtn`.

### Full power cycle (last resort)

Only if the GPU is truly wedged - `gpu-recover.sh` says so, or nothing responds at
all. Check `/var/log/vfio-gpu.log` first: if the last `BIND` shows
`ABORTING passthrough` instead of `BIND done`, the card never left the host and
nothing is wedged, so a normal reboot is enough. A warm reboot is often not enough
for a real wedge, because an NVIDIA card can hold the bad state across it. Shut the
machine down, switch the PSU off at the back (or pull the plug),
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
