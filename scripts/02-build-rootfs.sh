#!/bin/bash
# Stage 1 of the Rocky LiveUSB: lay down a Rocky 10.2 root filesystem with our 6.18.34 kernel,
# CUDA, container runtime, and bench deps. (Stage 2 = make it a bootable image.)
# Runs on the Spark; non-destructive (writes only to /home/max/rocky-img).
set -e
docker run --rm -v /home/max:/host rockylinux/rockylinux:10 bash -c '
set -e
dnf install -y -q make kmod findutils >/dev/null 2>&1   # base image lacks these; needed for modules_install/depmod
R=/host/rocky-img/rootfs; rm -rf "$R"; mkdir -p "$R" /host/rocky-img
cat >/etc/yum.repos.d/cuda.repo <<EOF
[cuda]
name=cuda-rhel10-sbsa
baseurl=https://developer.download.nvidia.com/compute/cuda/repos/rhel10/sbsa/
enabled=1
gpgcheck=0
EOF
echo "[rootfs] installing base + boot + tooling into rootfs ..."
dnf -y --installroot="$R" --releasever=10 --setopt=install_weak_deps=False \
  install @core dracut dracut-config-generic systemd-udev kmod nvme-cli pciutils numactl \
  python3 python3-pip git curl grub2-efi-aa64 grub2-tools efibootmgr >/host/rocky-img/rootfs.log 2>&1 \
  || { echo "[rootfs] base install FAILED"; tail -8 /host/rocky-img/rootfs.log; exit 1; }
echo "[rootfs] base ok: $(du -sh $R | cut -f1)"
echo "[rootfs] installing CUDA toolkit + driver userspace ..."
cp /etc/yum.repos.d/cuda.repo "$R/etc/yum.repos.d/cuda.repo"
dnf -y --installroot="$R" --releasever=10 --setopt=install_weak_deps=False install \
  cuda-toolkit-13-0 >>/host/rocky-img/rootfs.log 2>&1 || echo "[rootfs] cuda step had issues (refine next pass)"
echo "[rootfs] installing our 6.18.34 kernel + modules ..."
cp /host/kbuild/linux-6.18.34/arch/arm64/boot/Image "$R/boot/vmlinuz-6.18.34"
make -C /host/kbuild/linux-6.18.34 modules_install INSTALL_MOD_PATH="$R" >>/host/rocky-img/rootfs.log 2>&1
echo "[rootfs] DONE — size: $(du -sh $R | cut -f1)"
echo ROOTFS-STAGE1-DONE
'
echo ROOTFS-JOB-DONE
