#!/bin/bash
# Build the OPEN NVIDIA module inside rockylinux:10 (gcc 14.3.1 el10 = the compiler the kernel was built with).
set -uo pipefail
LOG=/home/max/kbuild/nvbuild2.full.log
KO=/home/max/kbuild/driver-610/NVIDIA-Linux-aarch64-610.43.02/kernel-open
echo "=== build open module in rockylinux:10 (matching gcc-14 el10) ==="
sudo docker run --rm -v /home/max/kbuild:/kbuild rockylinux/rockylinux:10 bash -c '
  set -e
  dnf -y install gcc make kmod findutils >/dev/null 2>&1
  echo "container gcc: $(gcc --version | head -1)"
  cd /kbuild/driver-610/NVIDIA-Linux-aarch64-610.43.02/kernel-open
  make clean >/dev/null 2>&1 || true
  make -j"$(nproc)" SYSSRC=/kbuild/linux-6.18.34 modules
' > "$LOG" 2>&1
RC=$?
echo "container build rc=$RC"
echo "=== tail ==="; tail -20 "$LOG"
echo "=== .ko produced? ==="; ls -la "$KO"/*.ko 2>/dev/null || echo "(no .ko)"
echo "=== Unknown symbol / hard errors (carried-patch territory) ==="
grep -iE "unknown symbol|error:|undefined reference" "$LOG" | head -25 || echo "(none)"
echo "=== vermagic (MUST be exactly 6.18.34) ==="
for m in nvidia.ko nvidia-uvm.ko nvidia-modeset.ko nvidia-drm.ko; do
  [ -f "$KO/$m" ] && echo "$m -> $(modinfo -F vermagic "$KO/$m" 2>/dev/null)"
done
echo "BUILD2-DONE rc=$RC"
