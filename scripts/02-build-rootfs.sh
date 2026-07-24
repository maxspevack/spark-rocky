#!/bin/bash
# Stage 1 of the Rocky LiveUSB: lay down a *current* Rocky rootfs with our $KVER kernel,
# CUDA toolkit, and bench deps. (Stage 2 = make it a bootable image, step 04.)
# Parameterized via config/versions.env (KVER, ROCKY_RELEASEVER) — bump there to stay current.
# Non-destructive: writes only to $W/rocky-img. Runs on the Spark.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER, PAGE_SIZE
W="${W:-$(dirname "$HERE")}"                    # workdir: kernel tree + rootfs + image live here
# build.env: 01's resolved-KVER handoff (clk derives KVER from the source Makefile). Fail closed on
# staleness — a leftover build.env from a different source/pin must not silently steer this build.
if [ -f "$W/build.env" ]; then
  PIN_KVER=$KVER; source "$W/build.env"
  [ "${BUILD_KERNEL_SOURCE:-}" = "$KERNEL_SOURCE" ] || { echo "FATAL: stale build.env (built from '${BUILD_KERNEL_SOURCE:-?}', pin is '$KERNEL_SOURCE') — rerun 01-build-kernel.sh"; exit 1; }
  [ "$KERNEL_SOURCE" != kernelorg ] || [ "$KVER" = "$PIN_KVER" ] || { echo "FATAL: stale build.env (KVER $KVER != pinned $PIN_KVER) — rerun 01-build-kernel.sh"; exit 1; }
  [ "$KERNEL_SOURCE" != clk ] || [ "${BUILD_CLK_COMMIT:-}" = "$CLK_COMMIT" ] || { echo "FATAL: stale build.env (CLK_COMMIT moved) — rerun 01-build-kernel.sh"; exit 1; }
fi
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
# MediaTek MT7925 WiFi/BT firmware (#64). The shipped image carried NO firmware, so the GB10 radios
# never came up (dmesg -2, hardware init failed). Ship the mt7925 + regulatory blobs — UNCOMPRESSED
# (~2M): linux-firmware provides them as .zst, but a .zst load fails at the driver`s early boot probe
# on this platform while a plain .bin loads cleanly at the early driver probe (verified on the metal
# 2026-07-22). mt7925e loads
# post-switch-root, so rootfs .bin is found. Targeted copy, not the full ~hundreds-of-MB linux-firmware.
echo "[rootfs] installing MT7925 WiFi/BT firmware (uncompressed, #64) ..."
dnf install -y -q linux-firmware zstd >/dev/null 2>&1
mkdir -p "$R/usr/lib/firmware/mediatek/mt7925"
for f in /usr/lib/firmware/mediatek/mt7925/*.zst; do zstd -d -f -q "$f" -o "$R/usr/lib/firmware/mediatek/mt7925/$(basename "${f%.zst}")"; done
[ -f /usr/lib/firmware/regulatory.db.zst ] && zstd -d -f -q /usr/lib/firmware/regulatory.db.zst -o "$R/usr/lib/firmware/regulatory.db"
[ -f /usr/lib/firmware/regulatory.db.p7s ] && cp /usr/lib/firmware/regulatory.db.p7s "$R/usr/lib/firmware/regulatory.db.p7s" 2>/dev/null || true
echo "[rootfs] mt7925 fw: $(ls "$R/usr/lib/firmware/mediatek/mt7925/"*.bin 2>/dev/null | wc -l) files, regulatory.db $([ -f "$R/usr/lib/firmware/regulatory.db" ] && echo present || echo MISSING)"

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
