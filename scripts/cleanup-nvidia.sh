#!/bin/bash
# Remove stale nvidia modules, install ONLY the fresh verified build, re-depmod, confirm resolution.
set -uo pipefail
R=/media/max/rocky-root
KO=/home/max/kbuild/driver-610/NVIDIA-Linux-aarch64-610.43.02/kernel-open
echo "=== remove ALL existing nvidia*.ko under extra (stale dupes) ==="
sudo find "$R/lib/modules/6.18.34/extra" -name "nvidia*.ko" -print -delete
sudo rmdir "$R/lib/modules/6.18.34/extra/nvidia" 2>/dev/null || true
echo "=== install fresh verified build to extra/ ==="
sudo cp -v "$KO"/nvidia.ko "$KO"/nvidia-uvm.ko "$KO"/nvidia-modeset.ko "$KO"/nvidia-drm.ko "$KO"/nvidia-peermem.ko "$R/lib/modules/6.18.34/extra/"
echo "=== depmod (slow: 8240 modules off the stick) ==="
sudo depmod -b "$R" 6.18.34
echo "=== modprobe resolution (must point at extra/, fresh build) ==="
sudo chroot "$R" modprobe -S 6.18.34 --dry-run --show-depends nvidia 2>&1
sudo chroot "$R" modprobe -S 6.18.34 --dry-run --show-depends nvidia_uvm 2>&1
echo "=== confirm resolved == fresh build ==="
sudo cmp -s "$R/lib/modules/6.18.34/extra/nvidia.ko" "$KO/nvidia.ko" && echo "nvidia.ko IDENTICAL-to-fresh OK" || echo "STILL DIFFERS (bad)"
sync
echo "CLEANUP-DONE"
