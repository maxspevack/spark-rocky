#!/bin/bash
# Stage 1 of the Rocky LiveUSB: lay down a *current* Rocky rootfs with our $KVER kernel,
# CUDA toolkit, and bench deps. (Stage 2 = make it a bootable image, step 04.)
# Parameterized via config/versions.env (KVER, ROCKY_RELEASEVER) — bump there to stay current.
# Non-destructive: writes only to $W/rocky-img. Runs on the Spark.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER, PAGE_SIZE
W="${W:-$(dirname "$HERE")}"                    # workdir: kernel tree + rootfs + image live here
[ -d "$W/linux-$KVER" ] || { echo "FATAL: kernel tree $W/linux-$KVER missing — run 01-build-kernel.sh first"; exit 1; }

docker run --rm -v "$W":/host -e KVER="$KVER" -e RV="$ROCKY_RELEASEVER" rockylinux/rockylinux:10 bash -c '
set -euo pipefail
dnf install -y -q make kmod findutils >/dev/null 2>&1   # base image lacks these; needed for modules_install/depmod
R=/host/rocky-img/rootfs; rm -rf "$R"; mkdir -p "$R" /host/rocky-img
cat >/etc/yum.repos.d/cuda.repo <<EOF
[cuda]
name=cuda-rhel10-sbsa
baseurl=https://developer.download.nvidia.com/compute/cuda/repos/rhel10/sbsa/
enabled=1
gpgcheck=1
gpgkey=https://developer.download.nvidia.com/compute/cuda/repos/rhel10/sbsa/CDF6BA43.pub
EOF
# Import NVIDIAs CUDA repo signing key so the install below is signature-verified (Bruce: a
# gpgcheck=0 repo inside a signed release is self-contradicting). The repo file copied into the
# rootfs carries gpgkey= so runtime dnf on the colleagues box verifies too.
rpm --import https://developer.download.nvidia.com/compute/cuda/repos/rhel10/sbsa/CDF6BA43.pub
echo "[rootfs] installing base + boot + tooling (current Rocky $RV) ..."
dnf -y --installroot="$R" --releasever="$RV" --setopt=install_weak_deps=False \
  install @core dracut dracut-config-generic systemd-udev kmod nvme-cli pciutils numactl \
  python3 python3-pip git curl grub2-efi-aa64 grub2-tools efibootmgr >/host/rocky-img/rootfs.log 2>&1
echo "[rootfs] base ok: $(du -sh $R | cut -f1)"
cp /etc/yum.repos.d/cuda.repo "$R/etc/yum.repos.d/cuda.repo"
# Minimal CUDA, NOT the full cuda-toolkit-13-0 dev kit (~4.7G of nvcc/cuBLAS/samples that a BOOT image
# never uses). nvcc + cudart (~1G) is enough for proof-of-life vectorAdd; the installed box pulls the full
# toolkit + container stack post-install (the cuda.repo is configured here for exactly that).
echo "[rootfs] installing minimal CUDA (nvcc + cudart) ..."
dnf -y --installroot="$R" --releasever="$RV" --setopt=install_weak_deps=False install \
  cuda-nvcc-13-0 cuda-cudart-devel-13-0 >>/host/rocky-img/rootfs.log 2>&1
echo "[rootfs] installing our $KVER kernel + modules (stripped) ..."
cp /host/linux-$KVER/arch/arm64/boot/Image "$R/boot/vmlinuz-$KVER"
# INSTALL_MOD_STRIP=1: strip debug symbols on install. Without it the modules tree is ~8.9G of debug-laden
# .ko (and the --no-hostonly initramfs then packs all of it); stripped it is ~0.5G. Functionally identical.
make -C /host/linux-$KVER modules_install INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$R" >>/host/rocky-img/rootfs.log 2>&1
echo "[rootfs] DONE — size: $(du -sh $R | cut -f1)"
'
# Verify artifacts, not the banner (a soft-failed dnf step would otherwise pass silently).
R="$W/rocky-img/rootfs"
[ -f "$R/boot/vmlinuz-$KVER" ] || { echo "VERIFY-FAIL: no vmlinuz-$KVER in rootfs"; exit 1; }
[ -d "$R/lib/modules/$KVER" ] || { echo "VERIFY-FAIL: no /lib/modules/$KVER in rootfs"; exit 1; }
[ -e "$R/usr/local/cuda/bin/nvcc" ] || [ -e "$R/usr/local/cuda-13.0/bin/nvcc" ] || echo "WARN: nvcc not in rootfs (check rootfs.log)"
echo "ROOTFS-OK $KVER ($(du -sh "$R" | cut -f1))"
