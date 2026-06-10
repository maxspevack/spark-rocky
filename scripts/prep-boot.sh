#!/bin/bash
# Prep the Spark to one-time-boot Rocky 10.2 + 6.18.34 from the USB stick.
# De-risks the initramfs (USB/ext4 drivers) and arms a ONE-TIME grub entry. Does NOT reboot.
set -uo pipefail
RUUID=af342994-642c-4ef7-940e-fc4a23f0a8ea
echo "=== DGX OS baseline: $(uname -r) ==="
echo "=== verify stick sda2 ==="
sudo blkid /dev/sda2 2>/dev/null
[ "$(sudo blkid -s UUID -o value /dev/sda2 2>/dev/null)" = "$RUUID" ] || { echo "ABORT: sda2 UUID != $RUUID"; exit 1; }
sudo mkdir -p /mnt/r2
sudo umount /mnt/r2 2>/dev/null
sudo mount /dev/sda2 /mnt/r2 || { echo "ABORT: cannot mount sda2"; exit 1; }
echo "--- /boot on stick ---"; ls -la /mnt/r2/boot/ | grep -E "6\.18\.34|init"
echo "--- os-release ---"; grep PRETTY_NAME /mnt/r2/etc/os-release 2>/dev/null
echo "--- modules present? ---"; ls /mnt/r2/lib/modules/ 2>/dev/null
# chroot prep
for d in proc sys dev dev/pts run; do sudo mount --bind /$d /mnt/r2/$d 2>/dev/null; done
echo "=== check initramfs for USB + ext4 drivers (the #1 first-boot risk) ==="
HAVE=$(sudo chroot /mnt/r2 lsinitrd /boot/initramfs-6.18.34.img 2>/dev/null | grep -cE "usb_storage|usb-storage|xhci_hcd|xhci-hcd|xhci_pci")
echo "USB-driver hits in current initramfs: ${HAVE:-0}"
if [ "${HAVE:-0}" -lt 1 ]; then
  echo "=== regenerating initramfs WITH usb/xhci/ext4/nvme drivers ==="
  sudo chroot /mnt/r2 dracut -f --add-drivers "usb_storage xhci_hcd xhci_pci ehci_hcd ext4 nvme nvme_core" /boot/initramfs-6.18.34.img 6.18.34 2>&1 | tail -6
  echo "--- recheck ---"; sudo chroot /mnt/r2 lsinitrd /boot/initramfs-6.18.34.img 2>/dev/null | grep -E "usb_storage|xhci" | head -3
else
  echo "initramfs already carries USB drivers — leaving it untouched"
fi
for d in dev/pts dev sys proc run; do sudo umount /mnt/r2/$d 2>/dev/null; done
sync; sudo umount /mnt/r2
echo "=== arm ONE-TIME DGX-grub boot into Rocky ==="
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
echo "PREP-DONE -- reboot the box and WATCH THE MONITOR. One-time: a power-cycle returns to DGX OS."
