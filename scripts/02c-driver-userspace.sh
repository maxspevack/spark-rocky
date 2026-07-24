#!/bin/bash
# Stage 1c: install matched $DRIVER_VER driver USERSPACE into the rootfs via the .run (--no-kernel-modules),
# sidestepping the dnf dkms/kmod dependency chain. The open .ko (02b, in extra/) is the kernel side.
# Parameterized via config/versions.env. Reuses the .run that 02b downloaded to $W/driver-610.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # DRIVER_VER, DRIVER_SHA256
W="${W:-$(dirname "$HERE")}"
[ -d "$W/rocky-img/rootfs" ] || { echo "FATAL: rootfs missing — run 02-build-rootfs.sh first"; exit 1; }

docker run --rm --privileged -v "$W":/host -e DRIVER_VER="$DRIVER_VER" -e DRIVER_SHA256="$DRIVER_SHA256" rockylinux/rockylinux:10 bash -c '
set -euo pipefail
R=/host/rocky-img/rootfs
RUN=NVIDIA-Linux-aarch64-$DRIVER_VER.run
SRC=/host/driver-610/$RUN
[ -f "$SRC" ] || { echo "FATAL: $SRC missing — run 02b first (it downloads the .run)"; exit 1; }
# Fail-closed: same pinned-hash gate as 02b (each stage is standalone-runnable; verify at point of use).
echo "$DRIVER_SHA256  $SRC" | sha256sum -c - >/dev/null 2>&1 \
  || { echo "FATAL: $SRC sha256 != pinned DRIVER_SHA256 (versions.env) — refusing to install"; exit 1; }
cp "$SRC" "$R/tmp/"
for m in proc sys dev dev/pts; do mkdir -p "$R/$m"; mount --bind "/$m" "$R/$m" 2>/dev/null || true; done
echo "=== running .run userspace-only inside the rootfs chroot ==="
chroot "$R" /bin/bash -c "cd /tmp && sh $RUN --no-kernel-modules --no-questions --ui=none --no-x-check --no-nouveau-check --install-libglvnd 2>&1 | tail -12"
for m in dev/pts dev sys proc; do umount -l "$R/$m" 2>/dev/null || true; done
'
# Verify userspace actually landed in the rootfs.
R="$W/rocky-img/rootfs"
[ -x "$R/usr/bin/nvidia-smi" ] || { echo "VERIFY-FAIL: nvidia-smi not in rootfs"; exit 1; }
ls "$R"/usr/lib64/libcuda.so* >/dev/null 2>&1 || { echo "VERIFY-FAIL: libcuda.so not in rootfs"; exit 1; }
echo "DRV-USERSPACE-OK: nvidia-smi + libcuda in rootfs ($(du -sh "$R" | cut -f1))"
