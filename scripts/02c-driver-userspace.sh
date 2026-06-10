#!/bin/bash
# Install matched 610.43.02 driver USERSPACE into the rootfs via the .run (--no-kernel-modules),
# sidestepping the dnf dkms/kmod dependency chain. Our open .ko (already in extra/) is the kernel side.
docker run --rm --privileged -v /home/max:/host rockylinux/rockylinux:10 bash -c '
set -e
R=/host/rocky-img/rootfs
RUN=NVIDIA-Linux-aarch64-610.43.02.run
cd /tmp
[ -f "$RUN" ] || curl -fsSL -m180 -o "$RUN" "https://us.download.nvidia.com/XFree86/aarch64/610.43.02/$RUN" 2>/dev/null
cp "$RUN" "$R/tmp/"
for m in proc sys dev dev/pts; do mkdir -p "$R/$m"; mount --bind "/$m" "$R/$m" 2>/dev/null || true; done
echo "=== running .run userspace-only inside the rootfs chroot ==="
chroot "$R" /bin/bash -c "cd /tmp && sh $RUN --no-kernel-modules --no-questions --ui=none --no-x-check --no-nouveau-check --install-libglvnd 2>&1 | tail -12"
for m in dev/pts dev sys proc; do umount -l "$R/$m" 2>/dev/null || true; done
echo "=== nvidia-smi + libcuda + libnvidia-ml in rootfs? ==="
ls -la "$R/usr/bin/nvidia-smi" 2>/dev/null || echo "NO nvidia-smi"
ls "$R"/usr/lib64/libcuda.so* "$R"/usr/lib64/libnvidia-ml.so* 2>/dev/null | head
echo "rootfs size: $(du -sh $R 2>/dev/null | cut -f1)"
'
echo DRV2-DONE
