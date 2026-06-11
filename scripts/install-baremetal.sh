#!/bin/bash
# Install the PROVEN running Rocky (USB) onto the internal NVMe as bare metal. Run from the booted USB Rocky.
# DESTRUCTIVE: wipes /dev/nvme0n1 (DGX OS). The USB remains as recovery.
# Uses parted (present in rootfs); installs dosfstools+rsync from BaseOS; cp -ax fallback if rsync absent.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER
TGT=/dev/nvme0n1
echo "=== Rocky $ROCKY_RELEASEVER + $KVER -> bare metal on $TGT ==="
SRC=$(findmnt -no SOURCE /); echo "running root: $SRC"
[ "$SRC" = "/dev/sda2" ] || { echo "ABORT: not running from USB /dev/sda2 (got $SRC)"; exit 1; }
[ -b "$TGT" ] && [ "$(lsblk -dno TRAN "$TGT" 2>/dev/null)" != usb ] || { echo "ABORT: $TGT not a safe internal target"; exit 1; }
echo "=== ensure format/copy tools (parted already present) ==="
dnf -y install dosfstools rsync 2>&1 | tail -2 || true
command -v parted   >/dev/null || { echo "ABORT: parted missing"; exit 1; }
command -v mkfs.vfat>/dev/null || { echo "ABORT: mkfs.vfat (dosfstools) unavailable — cannot format EFI"; exit 1; }
command -v mkfs.ext4>/dev/null || { echo "ABORT: mkfs.ext4 missing"; exit 1; }
USE_RSYNC=0; command -v rsync >/dev/null && USE_RSYNC=1
echo "rsync available: $USE_RSYNC (0 = use cp -ax)"
umount -R /mnt/dgx 2>/dev/null; umount ${TGT}p1 ${TGT}p2 2>/dev/null; true
echo ">>> WIPING $TGT <<<"
wipefs -a "$TGT" 2>/dev/null || true
parted -s "$TGT" mklabel gpt
parted -s "$TGT" mkpart EFI  fat32 1MiB 1025MiB
parted -s "$TGT" set 1 esp on
parted -s "$TGT" mkpart root ext4  1025MiB 100%
partprobe "$TGT"; sleep 2
lsblk -o NAME,SIZE,FSTYPE "$TGT"
mkfs.vfat -F32 -n ROCKYEFI ${TGT}p1 >/dev/null
mkfs.ext4 -F -L rocky-root ${TGT}p2 >/dev/null
mkdir -p /mnt/tgt; mount ${TGT}p2 /mnt/tgt; mkdir -p /mnt/tgt/boot/efi; mount ${TGT}p1 /mnt/tgt/boot/efi
echo "=== copy proven system -> nvme (slow part: USB read) ==="
if [ "$USE_RSYNC" = 1 ]; then
  rsync -aHAXx --exclude='/tmp/*' --exclude='/var/tmp/*' / /mnt/tgt/; echo "rsync rc=$?"
else
  for d in /*; do case "$d" in /proc|/sys|/dev|/run|/tmp|/mnt|/media|/boot) continue;; esac; cp -ax "$d" /mnt/tgt/; done
  mkdir -p /mnt/tgt/boot; for b in /boot/*; do [ "$b" = /boot/efi ] && continue; cp -ax "$b" /mnt/tgt/boot/; done
  mkdir -p /mnt/tgt/{proc,sys,dev,run,tmp,mnt,media,var/tmp}; echo "cp -ax done"
fi
RUUID=$(blkid -s UUID -o value ${TGT}p2); EUUID=$(blkid -s UUID -o value ${TGT}p1)
printf 'UUID=%s / ext4 defaults 0 1\nUUID=%s /boot/efi vfat umask=0077,shortname=winnt,nofail 0 2\n' "$RUUID" "$EUUID" > /mnt/tgt/etc/fstab
echo "fstab:"; cat /mnt/tgt/etc/fstab
for d in proc sys dev dev/pts run; do mount --bind /$d /mnt/tgt/$d; done
cp -f /etc/resolv.conf /mnt/tgt/etc/resolv.conf 2>/dev/null || true
chroot /mnt/tgt /bin/bash -c "
set -e
dnf -y install grub2-efi-aa64 shim-aa64 grub2-tools efibootmgr >/dev/null 2>&1 || echo 'WARN dnf grub'
mkdir -p /boot/efi/EFI/rocky
grub2-mkconfig -o /boot/efi/EFI/rocky/grub.cfg 2>&1 | tail -2
grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tail -1
EFIBIN=\$([ -f /boot/efi/EFI/rocky/shimaa64.efi ] && echo '\\\\EFI\\\\rocky\\\\shimaa64.efi' || echo '\\\\EFI\\\\rocky\\\\grubaa64.efi')
efibootmgr -c -d $TGT -p 1 -L 'Rocky-10.2-GB10' -l \"\$EFIBIN\" 2>&1 | tail -1 || true
echo '--- ESP ---'; ls -R /boot/efi/EFI 2>/dev/null | head -25
echo -n '--- grub.cfg $KVER entries: '; grep -c $KVER /boot/efi/EFI/rocky/grub.cfg 2>/dev/null || echo 0
echo '--- boot order ---'; efibootmgr 2>/dev/null | grep -iE 'BootOrder|Rocky'
"
for d in dev/pts dev sys proc run; do umount /mnt/tgt/$d 2>/dev/null; done
sync; umount /mnt/tgt/boot/efi; umount /mnt/tgt
echo "=== INSTALL-DONE: bare-metal Rocky on $TGT ==="
