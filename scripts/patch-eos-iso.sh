#!/usr/bin/env bash
# Remaster an EndeavourOS (archiso / systemd-boot) ISO so its bootloader auto-selects
# the NVIDIA entry with a 1-second timeout.
#
# Why: in single-GPU passthrough the guest has NO emulated display, so the boot MENU
# is invisible until the real GPU's driver brings the monitor up. If the menu default
# is the open-source/nouveau entry, a Blackwell card (RTX 50) shows nothing and you
# are stuck. Defaulting to the NVIDIA entry means the ISO auto-boots the proprietary
# driver env after 1s even with an invisible menu, and the screen lights up when
# nvidia KMS loads.
#
# Usage:  sudo ./patch-eos-iso.sh /path/to/EndeavourOS.iso [output.iso]
# Works on a COPY - the original ISO is left untouched.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
SRC="${1:?usage: patch-eos-iso.sh SRC.iso [OUT.iso]}"
OUT="${2:-${SRC%.iso}_gpu.iso}"

echo ">> copying $SRC -> $OUT"
cp --reflink=auto -- "$SRC" "$OUT"

loop=$(losetup -fP --show -- "$OUT")
MP=$(mktemp -d)
cleanup(){ umount "$MP" 2>/dev/null || true; rmdir "$MP" 2>/dev/null || true; losetup -d "$loop" 2>/dev/null || true; }
trap cleanup EXIT
echo ">> loop device: $loop"

# systemd-boot lives on the FAT ESP partition (the archiso appends it). Find it.
esp=""
for p in "${loop}"p*; do
  [ -e "$p" ] || continue
  [ "$(blkid -o value -s TYPE "$p" 2>/dev/null || true)" = vfat ] && { esp="$p"; break; }
done
[ -n "$esp" ] || { echo "!! no FAT ESP partition found - not an archiso/systemd-boot ISO?"; exit 1; }
echo ">> ESP partition: $esp"

mount "$esp" "$MP"
LC="$MP/loader/loader.conf"
[ -f "$LC" ] || { echo "!! $LC not found"; exit 1; }

# locate the NVIDIA loader entry
nv=$(ls "$MP/loader/entries/" 2>/dev/null | grep -iE 'nv|nvidia' | head -1 || true)
[ -n "$nv" ] || { echo "!! no NVIDIA entry under loader/entries/:"; ls "$MP/loader/entries/"; exit 1; }
echo ">> NVIDIA entry: $nv"

echo ">> loader.conf BEFORE:"; cat "$LC"
grep -q '^default'  "$LC" && sed -i "s|^default .*|default $nv|"  "$LC" || echo "default $nv"  >> "$LC"
grep -q '^timeout'  "$LC" && sed -i "s|^timeout .*|timeout 1|"    "$LC" || echo "timeout 1"    >> "$LC"
echo ">> loader.conf AFTER:";  cat "$LC"

sync
echo ">> done. Point your VM's CDROM at:  $OUT"
