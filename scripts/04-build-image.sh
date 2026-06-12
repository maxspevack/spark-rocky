#!/bin/bash
# Build a bootable Rocky + $KVER disk IMAGE on the fast NVMe (fast small-file writes),
# then stream it to the USB stick in one sequential dd. Runs on the Spark as root.
# Parameterized via config/versions.env. The dd target is guarded: it MUST be a removable USB.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER
W="${W:-$(dirname "$HERE")}"
R="$W/rocky-img/rootfs"
IMG="$W/rocky-img/rocky-gb10.img"
DEV="${DEV:-/dev/sda}"
MNT=/mnt/rimg
[ -d "$R" ] || { echo "FATAL: rootfs missing — run 02/02b/02c first"; exit 1; }

# We build the IMAGE first — no USB required. Flashing to a physical USB is an OPTIONAL final step
# (guarded so it can only ever touch a removable USB, never the NVMe). The vend flow stops at the
# image: 05-package-image.sh consumes $IMG and colleagues write it to their own USB with an imager.

RSZ=$(du -sB1G "$R" | cut -f1); IMGSZ=$(( ${RSZ%G} + 2 ))   # +2G margin covers chroot pkg adds + initramfs + ext4 overhead
echo "rootfs ${RSZ} -> image ${IMGSZ}G"
rm -f "$IMG"; truncate -s ${IMGSZ}G "$IMG"
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart EFI fat32 1MiB 1025MiB
parted -s "$IMG" set 1 esp on
parted -s "$IMG" mkpart root ext4 1025MiB 100%
LOOP=$(losetup --find --show -P "$IMG"); sleep 1; echo "loop=$LOOP"
mkfs.fat -F32 -n ROCKYEFI ${LOOP}p1 >/dev/null
mkfs.ext4 -F -q -L rocky-root ${LOOP}p2
EFI_UUID=$(blkid -s UUID -o value ${LOOP}p1); ROOT_UUID=$(blkid -s UUID -o value ${LOOP}p2)
echo "EFI=$EFI_UUID ROOT=$ROOT_UUID"

mkdir -p "$MNT"; mount ${LOOP}p2 "$MNT"; mkdir -p "$MNT"/boot/efi; mount ${LOOP}p1 "$MNT"/boot/efi
echo "=== populate (fast, on NVMe) ==="; cp -a "$R"/. "$MNT"/
cat > "$MNT"/etc/fstab <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$EFI_UUID /boot/efi vfat umask=0077,shortname=winnt 0 2
EOF
sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$MNT"/etc/selinux/config 2>/dev/null||true
mkdir -p "$MNT"/root/.ssh && cp /root/.ssh/authorized_keys "$MNT"/root/.ssh/authorized_keys 2>/dev/null \
  && chmod 700 "$MNT"/root/.ssh && chmod 600 "$MNT"/root/.ssh/authorized_keys
mkdir -p "$MNT"/boot/grub2
cat > "$MNT"/boot/grub2/grub.cfg <<EOF
set timeout=5
set default=0
insmod all_video
menuentry 'Rocky $ROCKY_RELEASEVER + $KVER (GB10)' {
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID ro rootwait iommu.passthrough=0 init_on_alloc=0 console=tty0 console=ttyS0,921600 earlycon=uart,mmio32,0x16A00000 selinux=0
  initrd /boot/initramfs-$KVER.img
}
EOF
for m in proc sys dev dev/pts; do mount --bind /$m "$MNT"/$m; done
mount -t tmpfs -o size=20G tmpfs "$MNT"/var/tmp   # dracut scratch in RAM, not the image root
chroot "$MNT" /bin/bash <<CHROOT
set -e
dnf install -y -q grub2-efi-aa64 grub2-efi-aa64-modules shim-aa64 dracut-network NetworkManager openssh-server zstd 2>/dev/null || true
echo 'root:rocky' | chpasswd   # DEV-IMAGE default — this box is LAN-only + reinstalled on demand; change before exposing off-LAN
systemctl enable sshd NetworkManager serial-getty@ttyS0.service getty@tty1.service 2>/dev/null || true
# GB10 unified memory: swap-on-overcommit hangs the box ("zombie" instead of a clean CUDA OOM). Disable swap.
# (fstab here carries no swap; this mask is belt-and-suspenders so nothing activates swap at runtime.)
systemctl mask swap.target 2>/dev/null || true
mkdir -p /var/log/journal   # persistent journald — a thermal/OOM event must survive a power-off for forensics (volatile default lost the 2026-06-11 crash logs)
dracut --force --no-hostonly --compress zstd --add-drivers "usb_storage uas xhci_pci xhci_hcd ehci_pci ext4 nvme" --kver $KVER /boot/initramfs-$KVER.img $KVER
CHROOT
# RHEL ships a PREBUILT grubaa64.efi (grub2-efi-aa64) — grub2-install --target=arm64-efi does NOT work here
# (no /usr/lib/grub/arm64-efi modules; it errors on modinfo.sh). The prebuilt binary reads its config from
# /EFI/rocky/grub.cfg (baked-in prefix, confirmed against the proven bare-metal box). So: write a
# self-contained menuentry there, and copy the prebuilt binary to the UEFI removable fallback
# /EFI/BOOT/BOOTAA64.EFI so the firmware boots the USB as removable media.
install -D -m644 "$MNT/boot/efi/EFI/rocky/grubaa64.efi" "$MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI" 2>/dev/null || true
cat > "$MNT/boot/efi/EFI/rocky/grub.cfg" <<EOF
set timeout=5
set default=0
insmod all_video
menuentry 'Rocky $ROCKY_RELEASEVER + $KVER (GB10)' {
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID ro rootwait iommu.passthrough=0 init_on_alloc=0 console=tty0 console=ttyS0,921600 earlycon=uart,mmio32,0x16A00000 selinux=0
  initrd /boot/initramfs-$KVER.img
}
EOF
# Also place the config at the self-relative path, covering both possible prefixes of the prebuilt binary.
cp -f "$MNT/boot/efi/EFI/rocky/grub.cfg" "$MNT/boot/efi/EFI/BOOT/grub.cfg" 2>/dev/null || true
# Ship the GPU proof-of-life + the passive thermal/mem logger IN the image (run /root/proof-of-life.sh;
# run /root/templog.sh alongside a benchmark for a forensic trace — logging only, it throttles nothing).
[ -f "$HERE/proof-of-life.sh" ] && install -m755 "$HERE/proof-of-life.sh" "$MNT/root/proof-of-life.sh"
[ -f "$HERE/templog.sh" ] && install -m755 "$HERE/templog.sh" "$MNT/root/templog.sh"
# Verify the built image carries kernel + initramfs + grub BEFORE the flash (advisor: artifacts, not banners).
VERR=0
[ -f "$MNT/boot/vmlinuz-$KVER" ] || { echo "VERIFY-FAIL: no vmlinuz-$KVER in image"; VERR=1; }
ISZ=$(stat -c%s "$MNT/boot/initramfs-$KVER.img" 2>/dev/null || echo 0)
[ "$ISZ" -gt 5000000 ] || { echo "VERIFY-FAIL: initramfs-$KVER.img missing/tiny ($ISZ bytes)"; VERR=1; }
[ -f "$MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI" ] || { echo "VERIFY-FAIL: no /EFI/BOOT/BOOTAA64.EFI — USB would not boot as removable media"; VERR=1; }
[ -f "$MNT/boot/efi/EFI/rocky/grub.cfg" ] || { echo "VERIFY-FAIL: no /EFI/rocky/grub.cfg (the prebuilt grub's config path)"; VERR=1; }
grep -q "vmlinuz-$KVER" "$MNT/boot/efi/EFI/rocky/grub.cfg" 2>/dev/null || { echo "VERIFY-FAIL: /EFI/rocky/grub.cfg does not reference vmlinuz-$KVER"; VERR=1; }
[ "$VERR" = 0 ] && echo "IMAGE-VERIFY-OK: vmlinuz-$KVER + initramfs-$KVER.img ($ISZ bytes) + BOOTAA64.EFI + /EFI/rocky/grub.cfg present"
for m in var/tmp dev/pts dev sys proc; do umount -l "$MNT"/$m 2>/dev/null||true; done
umount "$MNT"/boot/efi 2>/dev/null||true; umount "$MNT" 2>/dev/null||true; losetup -d "$LOOP"; sync
[ "$VERR" = 0 ] || { echo "ABORT: image failed verification"; exit 1; }
echo "IMAGE-VERIFY-OK -> $IMG ($(stat -c%s "$IMG" 2>/dev/null) bytes)"
# OPTIONAL flash: only if $DEV is a present, removable USB. Absent or non-USB -> skip cleanly (the
# image is the deliverable; 05 packages it; colleagues write it themselves). The guard makes
# flashing the NVMe impossible regardless of what $DEV is set to.
if [ "$(lsblk -dno TRAN "$DEV" 2>/dev/null|tr -d '[:space:]')" = usb ] && [ "$(lsblk -dno RM "$DEV" 2>/dev/null|tr -d '[:space:]')" = 1 ]; then
  echo "=== flashing $IMG -> $DEV ($(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null)) ==="
  for p in "$DEV"?*; do umount "$p" 2>/dev/null||true; done
  dd if="$IMG" of="$DEV" bs=16M oflag=direct status=progress; sync
  # backup GPT header lands mid-disk on a larger stick; relocate it so a clean reproducer shows no GPT errors.
  command -v sgdisk >/dev/null 2>&1 || dnf install -y -q gdisk 2>/dev/null || true
  command -v sgdisk >/dev/null 2>&1 && sgdisk -e "$DEV" >/dev/null 2>&1 && echo "GPT backup header relocated"
  partprobe "$DEV" 2>/dev/null || true; sync
  echo "USB-IMAGE-DONE $KVER -> $DEV"
else
  echo "no removable USB at $DEV — skipping flash. Image ready at $IMG; package it with scripts/05-package-image.sh."
fi
