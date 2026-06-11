#!/bin/bash
# Patch the USB stick rootfs in place: NVIDIA modules + GSP firmware + WiFi (mt7925) firmware + autoload.
# (No 32GB rewrite — small writes into the existing ext4.) WiFi connection profile is a separate step (needs creds).
set -uo pipefail
R=/media/max/rocky-root
KO=/home/max/kbuild/driver-610/NVIDIA-Linux-aarch64-610.43.02/kernel-open
FW=/home/max/kbuild/driver-610/NVIDIA-Linux-aarch64-610.43.02/firmware
DRV=610.43.02
mountpoint -q "$R" || sudo mount /dev/sda2 "$R"
sudo mount -o remount,rw "$R" 2>/dev/null || true
[ "$(findmnt -no SOURCE "$R" | head -1)" = /dev/sda2 ] || { echo "ABORT: $R is not /dev/sda2"; findmnt "$R"; exit 1; }

echo "=== 1. install nvidia .ko into rootfs /lib/modules/6.18.34/extra/nvidia ==="
sudo mkdir -p "$R/lib/modules/6.18.34/extra/nvidia"
sudo cp -v "$KO"/nvidia.ko "$KO"/nvidia-uvm.ko "$KO"/nvidia-modeset.ko "$KO"/nvidia-drm.ko "$KO"/nvidia-peermem.ko "$R/lib/modules/6.18.34/extra/nvidia/"

echo "=== 2. depmod against the rootfs ==="
sudo depmod -b "$R" 6.18.34
echo "  nvidia.ko in modules.dep: $(sudo grep -c "extra/nvidia/nvidia.ko" "$R/lib/modules/6.18.34/modules.dep")"

echo "=== 3. GSP firmware -> /lib/firmware/nvidia/$DRV ==="
sudo mkdir -p "$R/lib/firmware/nvidia/$DRV"
sudo cp -v "$FW"/gsp_ga10x.bin "$FW"/gsp_tu10x.bin "$FW"/ucodes_ga10x.bin "$FW"/ucodes_tu10x.bin "$R/lib/firmware/nvidia/$DRV/" 2>/dev/null || true
sudo ls "$R/lib/firmware/nvidia/$DRV/"

echo "=== 4. WiFi mt7925 firmware (copy from running DGX OS, which uses the same chip) ==="
if [ -d /lib/firmware/mediatek ]; then
  sudo cp -r /lib/firmware/mediatek "$R/lib/firmware/" && echo "mediatek fw copied"
  sudo ls "$R/lib/firmware/mediatek/mt7925/" 2>/dev/null | head
else echo "WARN: no /lib/firmware/mediatek on host"; fi

echo "=== 5. autoload nvidia modules at boot ==="
printf "nvidia\nnvidia_uvm\nnvidia_modeset\n" | sudo tee "$R/etc/modules-load.d/nvidia.conf" >/dev/null

echo "=== 6. sanity: nvidia userspace present in rootfs? ==="
sudo test -f "$R/usr/bin/nvidia-smi" && echo "nvidia-smi: present ($(sudo chroot "$R" nvidia-smi --version 2>/dev/null | head -1))" || echo "WARN: nvidia-smi missing"
sync
echo "PATCH-DONE (modules+GSP+wifi-fw staged). Next: WiFi connection profile (needs SSID/pass), then reboot."
