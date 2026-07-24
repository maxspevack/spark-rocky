#!/bin/bash
# Stage 1 of the Rocky LiveUSB: lay down a *current* Rocky rootfs with our $KVER kernel,
# CUDA toolkit, and bench deps. (Stage 2 = make it a bootable image, step 04.)
# Parameterized via config/versions.env (KVER, ROCKY_RELEASEVER) — bump there to stay current.
# Non-destructive: writes only to $W/rocky-img. Runs on the Spark.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER, PAGE_SIZE
W="${W:-$(dirname "$HERE")}"                    # workdir: kernel tree + rootfs + image live here
source "$HERE/lib/build-env-gate.sh"   # fail-closed staleness gate on 01's build.env (one impl — audit #70 C1)
[ -d "$W/linux-$KVER" ] || { echo "FATAL: kernel tree $W/linux-$KVER missing — run 01-build-kernel.sh first"; exit 1; }
# #59: the kernel installs from 01's rpm — KRPM (from build.env) is required, and the file must exist.
[ -n "${KRPM:-}" ] || { echo "FATAL: KRPM not set — build.env predates the rpm pipeline; rerun 01-build-kernel.sh"; exit 1; }
[ -f "$W/$KRPM" ]  || { echo "FATAL: kernel rpm $W/$KRPM missing — rerun 01-build-kernel.sh"; exit 1; }

docker run --rm -v "$W":/host -e KVER="$KVER" -e KRPM="$KRPM" -e RV="$ROCKY_RELEASEVER" -e CUDA_VER="$CUDA_VER" rockylinux/rockylinux:10 bash -c '
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
  cuda-nvcc-${CUDA_VER} cuda-cudart-devel-${CUDA_VER} >>/host/rocky-img/rootfs.log 2>&1
# MediaTek MT7925 WiFi/BT firmware (#64) — stock Rocky RPMs, zero hand-copied files. el10_2 splits
# firmware per vendor: mt7xxx-firmware owns the mt7925 blobs (~9M, requires only the whence license
# file — NOT the full linux-firmware set) and wireless-regdb owns regulatory.db. Blobs ship compressed
# (.xz in el10_2; .zst in other builds) and the KERNEL decompresses at request time — XZ support was
# inherited, ZSTD is enabled by 01. The original "a .zst load fails at the driver early-boot probe on
# this platform" (2026-07-22) was a MISDIAGNOSIS: the kernel simply lacked FW_LOADER_COMPRESS_ZSTD.
# mt7925e loads post-switch-root, so rootfs RPMs are found. Everything here is rpm-owned: rpm -qf
# answers for every blob on the box.
echo "[rootfs] installing MT7925 WiFi/BT firmware RPMs (mt7xxx-firmware + wireless-regdb, #64) ..."
dnf install -y -q --installroot="$R" --releasever=$RV mt7xxx-firmware wireless-regdb >>/host/rocky-img/rootfs.log 2>&1 \
  || { echo "VERIFY-FAIL: firmware rpm install failed (#64) — see rootfs.log"; exit 1; }
ls "$R/usr/lib/firmware/mediatek/mt7925/"WIFI_RAM_CODE* >/dev/null 2>&1 || { echo "VERIFY-FAIL: no mt7925 blobs in rootfs (#64)"; exit 1; }
[ -e "$R/usr/lib/firmware/regulatory.db" ] || { echo "VERIFY-FAIL: regulatory.db missing (#64)"; exit 1; }
echo "[rootfs] mt7925 fw: $(ls "$R/usr/lib/firmware/mediatek/mt7925/" | wc -l) blobs (rpm-owned: mt7xxx-firmware), regulatory.db present"

echo "[rootfs] installing our $KVER kernel from the RPM (#59): $KRPM ..."
# dnf-install (not cp + modules_install): the kernel lands in the image RPM database — rpm -q kernel is
# truthful on the booted box, and the NEVRA is provenance. tsflags=noscripts because the rpm %post runs
# kernel-install/BLS, and this image deliberately owns its own boot plumbing (static GRUB + our dracut in
# 04); we replicate the %post file copies ourselves below, deterministically. Modules arrive pre-stripped
# (01 builds the rpm with INSTALL_MOD_STRIP=1 — unstripped would be ~8.9G vs ~0.5G).
dnf install -y -q --installroot="$R" --releasever=$RV --nogpgcheck \
  --setopt=tsflags=noscripts /host/$KRPM >>/host/rocky-img/rootfs.log 2>&1 \
  || { echo "VERIFY-FAIL: dnf install of $KRPM failed — see rootfs.log"; exit 1; }
# The skipped %post copies vmlinuz/System.map/config from /lib/modules/$KVER/ to /boot; do it ourselves.
for f in vmlinuz System.map config; do
  cp "$R/lib/modules/$KVER/$f" "$R/boot/$f-$KVER" || { echo "VERIFY-FAIL: $f missing from the kernel rpm"; exit 1; }
done
depmod -b "$R" "$KVER"
echo "[rootfs] DONE — size: $(du -sh $R | cut -f1)"
'
# Verify artifacts, not the banner (a soft-failed dnf step would otherwise pass silently).
R="$W/rocky-img/rootfs"
[ -f "$R/boot/vmlinuz-$KVER" ] || { echo "VERIFY-FAIL: no vmlinuz-$KVER in rootfs"; exit 1; }
[ -d "$R/lib/modules/$KVER" ] || { echo "VERIFY-FAIL: no /lib/modules/$KVER in rootfs"; exit 1; }
# #59: the kernel must be IN the image rpm database (the point of the rpm pipeline — truthful rpm -q).
rpm --root "$R" -q kernel >/dev/null 2>&1 || { echo "VERIFY-FAIL: kernel not in the rootfs rpm database"; exit 1; }
[ -e "$R/usr/local/cuda/bin/nvcc" ] || [ -e "$R/usr/local/cuda-13.0/bin/nvcc" ] || echo "WARN: nvcc not in rootfs (check rootfs.log)"
echo "ROOTFS-OK $KVER ($(du -sh "$R" | cut -f1))"
