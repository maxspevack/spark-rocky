#!/bin/bash
# Build the kernel selected by KERNEL_SOURCE (kernelorg tarball today; CLK planned -- #52) for aarch64
# with the GB10 config, in a Rocky 10 container. The which-kernel knob makes A/B builds trivial.
# Side benefit: olddefconfig drops any GB10 symbol absent from vanilla $KVER — that readout
# tells us exactly what's NVIDIA-carried vs Tier-1 config. Non-destructive (container build).
# Parameterized via config/versions.env (KVER). The base config carries forward across point
# releases; olddefconfig adapts it to $KVER.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER, PAGE_SIZE
W="${W:-$(dirname "$HERE")}"
CONFIG="${CONFIG:-$HERE/../$KCONFIG}"   # base .config from versions.env KCONFIG (olddefconfig adapts it to $KVER)
[ -f "$CONFIG" ] || { echo "FATAL: base config $CONFIG missing"; exit 1; }
mkdir -p "$W"; cp "$CONFIG" "$W/dgx-config"
docker run --rm -v "$W":/work -e KERNEL_SOURCE="$KERNEL_SOURCE" -e KVER="$KVER" -e KERNEL_SHA256="$KERNEL_SHA256" -e PAGE_SIZE="$PAGE_SIZE" rockylinux/rockylinux:10 bash -c '
set -e
echo "[build] installing toolchain..."
dnf install -y -q gcc make flex bison bc openssl-devel elfutils-libelf-devel elfutils-devel \
  ncurses-devel dwarves perl diffutils xz wget tar gawk findutils rsync which python3 zlib-devel >/dev/null 2>&1
cd /work
# Kernel SOURCE dispatch (the which-kernel knob). Each source produces a ./linux-$KVER tree.
case "$KERNEL_SOURCE" in
  kernelorg)
    # Stock kernel.org tarball. The v-major path is DERIVED from KVER (6.x, 7.x, ...) so a major bump
    # (6.18 -> 7.0) needs no script change -- only the KVER + KERNEL_SHA256 pins.
    MAJ="v${KVER%%.*}.x"
    [ -f linux-$KVER.tar.xz ] || wget -q "https://cdn.kernel.org/pub/linux/kernel/$MAJ/linux-$KVER.tar.xz"
    # Verify against the kernel.org-published SHA256 (pinned in versions.env) before trusting a byte:
    # a compromised CDN/MITM otherwise gets compiled and later GPG-signed in our name.
    [ -n "$KERNEL_SHA256" ] && { echo "$KERNEL_SHA256  linux-$KVER.tar.xz" | sha256sum -c - || { echo "FATAL: kernel tarball SHA256 mismatch"; exit 1; }; }
    rm -rf linux-$KVER && tar xf linux-$KVER.tar.xz
    ;;
  clk)
    # CIQ CLK source (GPL; CIQ redistributes it). NOT wired yet: needs the source fetch (git ref or
    # src.rpm) + kernel-release discovery, since the CLK release differs from KVER. Tracked in #52.
    echo "FATAL: KERNEL_SOURCE=clk is not wired yet (CIQ CLK fetch + release discovery -- #52)"; exit 1
    ;;
  *)
    echo "FATAL: unknown KERNEL_SOURCE=$KERNEL_SOURCE (expected: kernelorg | clk)"; exit 1
    ;;
esac
cd linux-$KVER
cp /work/dgx-config .config
# neutralize distro signing/cert baggage that breaks out-of-distro builds
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
  --set-str MODULE_SIG_KEY "" --disable MODULE_SIG --disable SECURITY_LOCKDOWN_LSM 2>/dev/null || true
# Page-size variant (default 4k). 64k flips the ARM64 page-size choice; olddefconfig recomputes
# PAGE_SHIFT/PGTABLE_LEVELS. NOTE: no LOCALVERSION suffix -- the kernel release stays plain $KVER
# (uname -r = $KVER); the 64k choice lives in the .config symbol + the provenance stamp, not in uname.
if [ "$PAGE_SIZE" = 64k ]; then
  scripts/config --disable ARM64_4K_PAGES --enable ARM64_64K_PAGES
  echo "[build] 64k page-size variant (CONFIG_ARM64_64K_PAGES; no uname suffix)"
fi
make olddefconfig >/work/olddefconfig-$KVER.log 2>&1
echo "===SIGNAL-READOUT=== (vanilla $KVER + GB10 config; ABSENT = not upstream in $KVER = carried)"
for s in ARM_SMMU_V3 ARM_SMMU_V3_SVA ARM_SMMU_V3_IOMMUFD TEGRA241_CMDQV IOMMU_SVA \
  PCI_ATS PCI_PASID PCI_PRI ARCH_TEGRA ARCH_TEGRA_241_SOC ARCH_TEGRA_264_SOC \
  ZONE_DEVICE HMM_MIRROR DEVICE_PRIVATE DEVICE_MIGRATION MEMORY_HOTPLUG \
  TEGRA_BPMP CLK_TEGRA_BPMP RESET_TEGRA_BPMP SOC_TEGRA_CBB TEGRA_MC TEGRA_HSP_MBOX \
  NVGRACE_EGM NVGRACE_GPU_VFIO_PCI NVIDIA_TEGRA410_C2C_PMU \
  R8169 MLX5_CORE MT7925E NVME_CORE ARM64_4K_PAGES ARM64_64K_PAGES ARM64_PAGE_SHIFT PGTABLE_LEVELS; do
  v=$(grep -E "^CONFIG_$s=" .config | cut -d= -f2)
  echo "CONFIG_$s = ${v:-ABSENT}"
done
echo "===BUILD-START==="
make -j"$(nproc)" Image modules >/work/build-$KVER.log 2>&1
echo "BUILD-RC=$?"
[ -f arch/arm64/boot/Image ] && echo "KERNEL-BUILT $KVER ($(ls -la arch/arm64/boot/Image | awk "{print \$5}") bytes)"
cp .config /work/config-$KVER
'
echo "KERNEL-JOB-DONE $KVER ($PAGE_SIZE pages)"
