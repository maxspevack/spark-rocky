#!/bin/bash
# Build vanilla $KVER aarch64 with the GB10-enabled config, in a Rocky 10 container.
# Side benefit: olddefconfig drops any GB10 symbol absent from vanilla $KVER — that readout
# tells us exactly what's NVIDIA-carried vs Tier-1 config. Non-destructive (container build).
# Parameterized via config/versions.env (KVER). The base config carries forward across point
# releases; olddefconfig adapts it to $KVER.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER
W="${W:-$(dirname "$HERE")}"
CONFIG="${CONFIG:-$HERE/../config/rocky-6.18.34-gb10.config}"   # base GB10 .config (olddefconfig adapts it to $KVER)
[ -f "$CONFIG" ] || { echo "FATAL: base config $CONFIG missing"; exit 1; }
mkdir -p "$W"; cp "$CONFIG" "$W/dgx-config"
docker run --rm -v "$W":/work -e KVER="$KVER" -e KERNEL_SHA256="$KERNEL_SHA256" rockylinux/rockylinux:10 bash -c '
set -e
echo "[build] installing toolchain..."
dnf install -y -q gcc make flex bison bc openssl-devel elfutils-libelf-devel elfutils-devel \
  ncurses-devel dwarves perl diffutils xz wget tar gawk findutils rsync which python3 zlib-devel >/dev/null 2>&1
cd /work
[ -f linux-$KVER.tar.xz ] || wget -q https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz
# Verify against the kernel.org-published SHA256 (pinned in versions.env) before trusting a byte
# of it — a compromised CDN/MITM otherwise gets compiled and later GPG-signed in our name.
[ -n "$KERNEL_SHA256" ] && { echo "$KERNEL_SHA256  linux-$KVER.tar.xz" | sha256sum -c - || { echo "FATAL: kernel tarball SHA256 mismatch"; exit 1; }; }
rm -rf linux-$KVER && tar xf linux-$KVER.tar.xz
cd linux-$KVER
cp /work/dgx-config .config
# neutralize distro signing/cert baggage that breaks out-of-distro builds
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
  --set-str MODULE_SIG_KEY "" --disable MODULE_SIG --disable SECURITY_LOCKDOWN_LSM 2>/dev/null || true
make olddefconfig >/work/olddefconfig-$KVER.log 2>&1
echo "===SIGNAL-READOUT=== (vanilla $KVER + GB10 config; ABSENT = not upstream in $KVER = carried)"
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
make -j"$(nproc)" Image modules >/work/build-$KVER.log 2>&1
echo "BUILD-RC=$?"
[ -f arch/arm64/boot/Image ] && echo "KERNEL-BUILT $KVER ($(ls -la arch/arm64/boot/Image | awk "{print \$5}") bytes)"
cp .config /work/config-$KVER
'
echo "KERNEL-JOB-DONE $KVER"
