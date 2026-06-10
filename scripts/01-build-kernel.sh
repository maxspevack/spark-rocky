#!/bin/bash
# Build vanilla 6.18.34 aarch64 with the DGX (GB10-enabled) config, in a Rocky 10 container.
# Side benefit: olddefconfig drops any DGX symbol absent from vanilla 6.18.34 — that readout
# tells us exactly what's NVIDIA-carried vs Tier-1 config. Non-destructive (container build).
set -e
W=/home/max/kbuild
mkdir -p "$W"
docker run --rm -v "$W":/work rockylinux/rockylinux:10 bash -c '
set -e
KVER=6.18.34
echo "[build] installing toolchain..."
dnf install -y -q gcc make flex bison bc openssl-devel elfutils-libelf-devel elfutils-devel \
  ncurses-devel dwarves perl diffutils xz wget tar gawk findutils rsync which python3 zlib-devel >/dev/null 2>&1
cd /work
[ -f linux-$KVER.tar.xz ] || wget -q https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz
rm -rf linux-$KVER && tar xf linux-$KVER.tar.xz
cd linux-$KVER
cp /work/dgx-config .config
# neutralize Ubuntu signing/cert baggage that breaks out-of-distro builds
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
  --set-str MODULE_SIG_KEY "" --disable MODULE_SIG --disable SECURITY_LOCKDOWN_LSM 2>/dev/null || true
make olddefconfig >/work/olddefconfig.log 2>&1
echo "===SIGNAL-READOUT=== (vanilla 6.18.34 + DGX config; ABSENT = not upstream in 6.18.34 = carried)"
for s in ARM_SMMU_V3 ARM_SMMU_V3_SVA ARM_SMMU_V3_IOMMUFD TEGRA241_CMDQV IOMMU_SVA \
  PCI_ATS PCI_PASID PCI_PRI ARCH_TEGRA ARCH_TEGRA_241_SOC ARCH_TEGRA_264_SOC \
  ZONE_DEVICE HMM_MIRROR DEVICE_PRIVATE DEVICE_MIGRATION MEMORY_HOTPLUG \
  TEGRA_BPMP CLK_TEGRA_BPMP RESET_TEGRA_BPMP SOC_TEGRA_CBB TEGRA_MC TEGRA_HSP_MBOX \
  NVGRACE_EGM NVGRACE_GPU_VFIO_PCI NVIDIA_TEGRA410_C2C_PMU \
  R8169 MLX5_CORE MT7925E NVME_CORE; do
  v=$(grep -E "^CONFIG_$s=" .config | cut -d= -f2)
  echo "CONFIG_$s = ${v:-ABSENT}"
done
echo "===BUILD-START==="
make -j"$(nproc)" Image modules >/work/build.log 2>&1
echo "BUILD-RC=$?"
[ -f arch/arm64/boot/Image ] && echo "KERNEL-BUILT $(ls -la arch/arm64/boot/Image | awk "{print \$5}") bytes"
'
echo "KERNEL-JOB-DONE"
