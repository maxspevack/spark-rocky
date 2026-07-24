#!/bin/bash
# Build the kernel selected by KERNEL_SOURCE for aarch64 with the GB10 config, in a Rocky 10 container.
# Supports two kernel sources (set KERNEL_SOURCE in config/versions.env):
#   kernelorg — vanilla kernel.org tarball (default, SHA256-verified, v-major derived from KVER)
#   clk       — CIQ Linux Kernel from GitHub (commit-pinned, uses CLK tree's own aarch64 config)
# Side benefit: olddefconfig drops any GB10 symbol absent from the tree — that readout
# tells us exactly what's carried vs Tier-1 config. Non-destructive (container build).
# Parameterized via config/versions.env (KVER, KERNEL_SOURCE, CLK_COMMIT, KCONFIG, etc).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER, PAGE_SIZE, KERNEL_SOURCE, CLK_*
W="${W:-$(dirname "$HERE")}"

# For kernelorg builds, copy the base config to the workdir (the container picks it up).
# For CLK builds, the config comes from inside the source tree — handled in the container.
case "$KERNEL_SOURCE" in
  kernelorg)
    CONFIG="${CONFIG:-$HERE/../$KCONFIG}"   # base .config from versions.env KCONFIG (olddefconfig adapts it to $KVER)
    [ -f "$CONFIG" ] || { echo "FATAL: base config $CONFIG missing"; exit 1; }
    mkdir -p "$W"; cp "$CONFIG" "$W/dgx-config"
    echo "[source] kernelorg: linux-$KVER"
    ;;
  clk)
    CLK_COMMIT="${CLK_COMMIT:?FATAL: CLK_COMMIT not set in versions.env}"
    echo "[source] CLK: ctrliq/kernel-src-tree commit $CLK_COMMIT"
    ;;
  *)
    echo "FATAL: unknown KERNEL_SOURCE=$KERNEL_SOURCE (expected: kernelorg | clk)"; exit 1
    ;;
esac

mkdir -p "$W"
docker run --rm -v "$W":/work \
  -e KERNEL_SOURCE="$KERNEL_SOURCE" -e KVER="$KVER" -e KERNEL_SHA256="$KERNEL_SHA256" \
  -e PAGE_SIZE="$PAGE_SIZE" -e CLK_COMMIT="${CLK_COMMIT:-}" \
  rockylinux/rockylinux:10 bash -c '
set -e
# Stage stopwatch (#70 build-speed): each STAGE-TIME line = seconds since the previous one. The speed
# work is measurement-driven — these lines are the measurements.
T0=$SECONDS; stage(){ echo "STAGE-TIME $1 $((SECONDS-T0))s"; T0=$SECONDS; }
echo "[build] installing toolchain..."
dnf install -y -q gcc make flex bison bc openssl openssl-devel elfutils-libelf-devel elfutils-devel \
  ncurses-devel dwarves perl diffutils xz wget tar gawk findutils rsync which python3 zlib-devel \
  rpm-build cpio kmod >/dev/null 2>&1   # openssl/rpm-build/cpio/kmod: binrpm-pkg build deps (#59)
stage toolchain-install
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
    # CIQ Linux Kernel (GPL; CIQ redistributes it). Pinned by commit SHA so the tarball is immutable.
    CLK_REPO=ctrliq/kernel-src-tree
    TARBALL="clk-${CLK_COMMIT}.tar.gz"
    [ -f "$TARBALL" ] || wget -q -O "$TARBALL" "https://github.com/$CLK_REPO/archive/$CLK_COMMIT.tar.gz" \
      || { rm -f "$TARBALL"; echo "FATAL: failed to download CLK tarball (commit $CLK_COMMIT)"; exit 1; }
    EXTRACT_DIR="$(basename "$CLK_REPO")-$CLK_COMMIT"
    rm -rf "$EXTRACT_DIR"
    tar xf "$TARBALL"
    # The CLK source tree defines the kernel version — derive it from the Makefile.
    # EXTRAVERSION is not parsed; CLK stable branches do not set it.
    CLK_V=$(sed -n "s/^VERSION *= *//p"    "$EXTRACT_DIR/Makefile")
    CLK_P=$(sed -n "s/^PATCHLEVEL *= *//p" "$EXTRACT_DIR/Makefile")
    CLK_S=$(sed -n "s/^SUBLEVEL *= *//p"   "$EXTRACT_DIR/Makefile")
    [ -n "$CLK_V" ] && [ -n "$CLK_P" ] && [ -n "$CLK_S" ] || { echo "FATAL: could not parse kernel version from $EXTRACT_DIR/Makefile"; exit 1; }
    KVER="${CLK_V}.${CLK_P}.${CLK_S}"
    echo "[source] CLK kernel version: $KVER (commit $CLK_COMMIT)"
    rm -rf "linux-$KVER"
    mv "$EXTRACT_DIR" "linux-$KVER"
    ;;
  *)
    echo "FATAL: unknown KERNEL_SOURCE=$KERNEL_SOURCE (expected: kernelorg | clk)"; exit 1
    ;;
esac
cd linux-$KVER

# --- Select config ---
if [ "$KERNEL_SOURCE" = clk ]; then
  # Use the CLK tree'"'"'s own aarch64 config (64k or 4k based on PAGE_SIZE).
  if [ "$PAGE_SIZE" = 64k ]; then
    cp ciq/configs/kernel-aarch64-64k.config .config
  else
    cp ciq/configs/kernel-aarch64.config .config
  fi
  # LINEAGE in uname (Max, 2026-07-17): clk builds carry CONFIG_LOCALVERSION="-clk" so uname -r,
  # /lib/modules, vermagic, the vmlinuz name, and the GRUB title all state the kernel is the CIQ
  # Linux Kernel, not kernel.org — the .el9-style distro convention. This refines (not reverses)
  # the suffix doctrine: uname carries SOURCE LINEAGE; config properties like page size stay out.
  scripts/config --set-str LOCALVERSION "-clk"
else
  cp /work/dgx-config .config
fi
# Neutralize distro signing/cert baggage on BOTH paths. The CLK configs carry MODULE_SIG=y with the
# default certs/signing_key.pem key path (verified at the pinned commit), so a tarball build would
# auto-generate an EPHEMERAL signing key and embed its cert in the kernel Image — nondeterministic
# bytes that break build reproducibility — while the out-of-tree open nvidia module stays unsigned
# regardless. Same reasoning as the kernelorg path; a .config choice, not a source patch.
# MODULE_SIG_ALL must be disabled EXPLICITLY: CLK'"'"'s RHEL-lineage patches decouple it from MODULE_SIG
# (it survives =y with MODULE_SIG off — a state upstream cannot express) and key the modules_install
# SIGN step on it, so an emptied key path dies in sign-file with an SSL DECODER error (hit on the
# GB10, 2026-07-16, CLK ciq-6.18.y @ b1a607d).
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
  --set-str MODULE_SIG_KEY "" --disable MODULE_SIG --disable MODULE_SIG_ALL \
  --disable SECURITY_LOCKDOWN_LSM 2>/dev/null || true
# Firmware loads straight from Rocky'"'"'s .zst-compressed firmware RPMs (#64): el10 ships blobs as .zst,
# and both inherited configs enable only XZ decompression — the exact gap that made the MT7925 radios
# dead-on-boot until 2026-07-23. The kernel decompresses at request time; the rootfs installs the stock
# firmware subpackages via dnf, no hand-decompressed files. A .config choice, not a source patch.
scripts/config --enable FW_LOADER_COMPRESS_ZSTD 2>/dev/null || true
# Page-size variant (default 4k). 64k flips the ARM64 page-size choice; olddefconfig recomputes
# PAGE_SHIFT/PGTABLE_LEVELS. NOTE: page size NEVER rides uname — it lives in the .config symbol +
# the provenance stamp. (Lineage DOES ride uname: the clk path sets LOCALVERSION="-clk" above.)
if [ "$PAGE_SIZE" = 64k ]; then
  scripts/config --disable ARM64_4K_PAGES --enable ARM64_64K_PAGES
  echo "[build] 64k page-size variant (CONFIG_ARM64_64K_PAGES; no uname suffix)"
fi
make olddefconfig >/work/olddefconfig-$KVER.log 2>&1
stage source-extract-config
# From here on KVER IS the kernel RELEASE (make kernelrelease = version + LOCALVERSION), not the
# bare pin: 6.18.38 for kernelorg, 6.18.38-clk for clk. The modules dir, vermagic, vmlinuz name,
# GRUB title, and provenance stamp all follow via build.env. Rename the tree dir to match so every
# downstream $W/linux-$KVER reference resolves.
SRCDIR=$(basename "$PWD")
KVER=$(make -s kernelrelease)
if [ "$SRCDIR" != "linux-$KVER" ]; then cd ..; rm -rf "linux-$KVER"; mv "$SRCDIR" "linux-$KVER"; cd "linux-$KVER"; fi
echo "[release] kernel release: $KVER ($KERNEL_SOURCE)"
echo "===SIGNAL-READOUT=== ($KERNEL_SOURCE $KVER + GB10 config; ABSENT = not in tree = carried)"
for s in ARM_SMMU_V3 ARM_SMMU_V3_SVA ARM_SMMU_V3_IOMMUFD TEGRA241_CMDQV IOMMU_SVA \
  PCI_ATS PCI_PASID PCI_PRI ARCH_TEGRA ARCH_TEGRA_241_SOC ARCH_TEGRA_264_SOC \
  ZONE_DEVICE HMM_MIRROR DEVICE_PRIVATE DEVICE_MIGRATION MEMORY_HOTPLUG \
  TEGRA_BPMP CLK_TEGRA_BPMP RESET_TEGRA_BPMP SOC_TEGRA_CBB TEGRA_MC TEGRA_HSP_MBOX \
  NVGRACE_EGM NVGRACE_GPU_VFIO_PCI NVIDIA_TEGRA410_C2C_PMU \
  R8169 MLX5_CORE MT7925E NVME_CORE FW_LOADER_COMPRESS_ZSTD ARM64_4K_PAGES ARM64_64K_PAGES ARM64_PAGE_SHIFT PGTABLE_LEVELS; do
  v=$(grep -E "^CONFIG_$s=" .config | cut -d= -f2)
  echo "CONFIG_$s = ${v:-ABSENT}"
done
echo "===BUILD-START==="
make -j"$(nproc)" Image modules >/work/build-$KVER.log 2>&1
echo "BUILD-RC=$?"
stage make-image-modules
[ -f arch/arm64/boot/Image ] && echo "KERNEL-BUILT $KVER ($(ls -la arch/arm64/boot/Image | awk "{print \$5}") bytes)"
cp .config /work/config-$KVER
# Package the built kernel as an RPM (#59): the appliance kernel is a first-class package — rpm -q
# truthful on the box, dnf-managed install/rollback, NEVRA provenance in 05. INSTALL_MOD_STRIP=1 is
# REQUIRED: unstripped modules balloon the rpm ~0.5G -> ~1.5G. RPMs land in rpmbuild/ inside the tree
# (kernel Makefile sets _topdir to the objtree); the main kernel rpm is copied to $W for 02/upgrade-metal.
# kernel-headers/kernel-devel subpackages are built too but deliberately NOT shipped (the open .ko
# builds against the tree, not the rpm — the decoupling is deliberate, see docs/build/build.md).
make -j"$(nproc)" INSTALL_MOD_STRIP=1 binrpm-pkg >/work/binrpm-$KVER.log 2>&1
stage binrpm-pkg
KRPM=$(ls rpmbuild/RPMS/aarch64/kernel-[0-9]*.rpm 2>/dev/null | head -1)
[ -n "$KRPM" ] || { echo "FATAL: binrpm-pkg produced no kernel rpm (#59) — see binrpm-$KVER.log"; exit 1; }
cp "$KRPM" /work/
KRPM=$(basename "$KRPM")
echo "KERNEL-RPM $KRPM ($(du -h /work/$KRPM | cut -f1))"
# Write the resolved-KVER handoff for the host + downstream scripts (02/02b/03/04/05/upgrade-metal).
# For kernelorg KVER equals the pin; for CLK it is derived from the source Makefile. The source +
# commit stamps let downstream fail closed on a STALE build.env (mode or pin moved since this build).
{ echo "KVER=$KVER"; echo "BUILD_KERNEL_SOURCE=$KERNEL_SOURCE"; echo "BUILD_CLK_COMMIT=${CLK_COMMIT:-}"; echo "KRPM=$KRPM"; } > /work/build.env
'
# Source the resolved KVER from the container (may differ from versions.env for CLK builds)
[ -f "$W/build.env" ] && source "$W/build.env"
echo "KERNEL-JOB-DONE $KVER ($KERNEL_SOURCE, $PAGE_SIZE pages)"
