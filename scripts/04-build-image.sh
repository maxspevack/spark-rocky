#!/bin/bash
# Build a bootable Rocky 10.2 + 6.18.34 disk IMAGE on the fast NVMe (fast small-file writes),
# then stream it to the USB stick in one sequential dd. Runs on the Spark as root.
set -uo pipefail
R=/home/max/rocky-img/rootfs
IMG=/home/max/rocky-img/rocky-gb10.img
DEV=/dev/sda
MNT=/mnt/rimg

[ "$(lsblk -dno TRAN "$DEV" 2>/dev/null|tr -d '[:space:]')" = usb ] \
  && [ "$(lsblk -dno RM "$DEV" 2>/dev/null|tr -d '[:space:]')" = 1 ] \
  || { echo "REFUSE: $DEV not removable USB"; exit 1; }

RSZ=$(du -sB1G "$R" | cut -f1); IMGSZ=$(( ${RSZ%G} + 14 ))
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
mkdir -p "$MNT"/root/.ssh && cp /home/max/.ssh/authorized_keys "$MNT"/root/.ssh/authorized_keys 2>/dev/null \
  && chmod 700 "$MNT"/root/.ssh && chmod 600 "$MNT"/root/.ssh/authorized_keys
mkdir -p "$MNT"/boot/grub2
cat > "$MNT"/boot/grub2/grub.cfg <<EOF
set timeout=5
set default=0
insmod all_video
menuentry 'Rocky 10.2 + 6.18.34 (GB10)' {
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  linux /boot/vmlinuz-6.18.34 root=UUID=$ROOT_UUID ro rootwait iommu.passthrough=0 init_on_alloc=0 console=tty0 console=ttyS0,921600 earlycon=uart,mmio32,0x16A00000 selinux=0
  initrd /boot/initramfs-6.18.34.img
}
EOF
for m in proc sys dev dev/pts; do mount --bind /$m "$MNT"/$m; done
mount -t tmpfs -o size=20G tmpfs "$MNT"/var/tmp   # dracut scratch in RAM, not the image root
chroot "$MNT" /bin/bash <<'CHROOT'
set -e
dnf install -y -q grub2-efi-aa64 grub2-efi-aa64-modules shim-aa64 dracut-network NetworkManager openssh-server 2>/dev/null || true
echo 'root:rocky' | chpasswd   # DEV-IMAGE default — this box is LAN-only + reinstalled on demand; change before exposing off-LAN
systemctl enable sshd NetworkManager serial-getty@ttyS0.service getty@tty1.service 2>/dev/null || true
dracut --force --no-hostonly --add-drivers "usb_storage uas xhci_pci xhci_hcd ehci_pci ext4 nvme" --kver 6.18.34 /boot/initramfs-6.18.34.img 6.18.34
grub2-install --target=arm64-efi --efi-directory=/boot/efi --removable --boot-directory=/boot --no-nvram
cp -f /boot/grub2/grub.cfg /boot/efi/EFI/BOOT/grub.cfg 2>/dev/null || true
CHROOT
for m in var/tmp dev/pts dev sys proc; do umount -l "$MNT"/$m 2>/dev/null||true; done
umount "$MNT"/boot/efi 2>/dev/null||true; umount "$MNT" 2>/dev/null||true; losetup -d "$LOOP"; sync
echo "=== image ready ($(ls -la $IMG|awk '{print $5}') bytes); streaming to $DEV ==="
for p in "$DEV"?*; do umount "$p" 2>/dev/null||true; done
dd if="$IMG" of="$DEV" bs=16M oflag=direct status=progress
sync
echo "USB-IMAGE-DONE"
