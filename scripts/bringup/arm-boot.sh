#!/bin/bash
# Kill any wedged prep, clean chroot mounts, arm a ONE-TIME DGX-grub boot into Rocky. No stick writes.
set -uo pipefail
RUUID=af342994-642c-4ef7-940e-fc4a23f0a8ea
echo "=== kill wedged prep + children ==="
sudo pkill -P 30627 2>/dev/null; sudo kill 30627 2>/dev/null
sudo pkill -x lsinitrd 2>/dev/null; sudo pkill -x dracut 2>/dev/null; sudo pkill -x xz 2>/dev/null; sudo pkill -x cpio 2>/dev/null
sleep 2
echo "=== release chroot bind-mounts + stick ==="
for d in dev/pts dev sys proc run; do sudo umount /mnt/r2/$d 2>/dev/null; done
sudo umount -l /mnt/r2 2>/dev/null
echo "=== confirm stick free, kernel+initramfs intact ==="
sudo blkid -s UUID -o value /dev/sda2
echo "=== arm ONE-TIME boot into Rocky ==="
sudo tee /etc/grub.d/40_custom >/dev/null <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry "Rocky-10.2-6.18.34-GB10" {
  insmod part_gpt
  insmod ext2
  insmod usb
  search --no-floppy --fs-uuid --set=root $RUUID
  linux /boot/vmlinuz-6.18.34 root=UUID=$RUUID ro rootwait iommu.passthrough=0 init_on_alloc=0 console=tty0 console=ttyS0,921600 earlycon=uart,mmio32,0x16A00000 selinux=0
  initrd /boot/initramfs-6.18.34.img
}
EOF
sudo chmod +x /etc/grub.d/40_custom
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
grep -q '^GRUB_DEFAULT=saved' /etc/default/grub || echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub >/dev/null
sudo update-grub 2>&1 | tail -3
sudo grub-reboot "Rocky-10.2-6.18.34-GB10" && echo "ONE-TIME-BOOT-ARMED-OK"
echo "ARM-DONE -- reboot + watch the monitor; one-time, power-cycle returns to DGX OS"
