#!/bin/bash
# Build the OPEN NVIDIA module standalone in rockylinux:10 (gcc 14.3.1 el10 = the compiler the kernel was
# built with). The headline finding: el10's gcc-14 compiles the open module against a stock upstream kernel
# with ZERO source changes, where the DGX-OS host's gcc-13 fails on -fmin-function-alignment=8.
# This is the proof/verify step (02b already builds the .ko into the rootfs). Asserts vermagic == $KVER.
# Parameterized via config/versions.env. Assumes 02b downloaded+extracted the driver to $W/driver-610.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER, PAGE_SIZE
W="${W:-$(dirname "$HERE")}"
# build.env: 01's resolved-KVER handoff (clk derives KVER from the source Makefile). Fail closed on
# staleness — a leftover build.env from a different source/pin must not silently steer this build.
if [ -f "$W/build.env" ]; then
  PIN_KVER=$KVER; source "$W/build.env"
  [ "${BUILD_KERNEL_SOURCE:-}" = "$KERNEL_SOURCE" ] || { echo "FATAL: stale build.env (built from '${BUILD_KERNEL_SOURCE:-?}', pin is '$KERNEL_SOURCE') — rerun 01-build-kernel.sh"; exit 1; }
  [ "$KERNEL_SOURCE" != kernelorg ] || [ "$KVER" = "$PIN_KVER" ] || { echo "FATAL: stale build.env (KVER $KVER != pinned $PIN_KVER) — rerun 01-build-kernel.sh"; exit 1; }
  [ "$KERNEL_SOURCE" != clk ] || [ "${BUILD_CLK_COMMIT:-}" = "$CLK_COMMIT" ] || { echo "FATAL: stale build.env (CLK_COMMIT moved) — rerun 01-build-kernel.sh"; exit 1; }
fi
EXPECT_VM="$KVER"   # the open module's vermagic must equal the kernel release, which is plain $KVER (no LOCALVERSION suffix)
LOG="$W/nvbuild.full.log"
KO="$W/driver-610/NVIDIA-Linux-aarch64-$DRIVER_VER/kernel-open"
[ -d "$KO" ] || { echo "FATAL: $KO missing — run 02b first (it downloads+extracts the driver)"; exit 1; }
echo "=== build open module in rockylinux:10 (matching gcc-14 el10) against $KVER ==="
docker run --rm -v "$W":/kbuild -e KVER="$KVER" -e DRIVER_VER="$DRIVER_VER" rockylinux/rockylinux:10 bash -c '
  set -e
  dnf -y install gcc make kmod findutils >/dev/null 2>&1
  echo "container gcc: $(gcc --version | head -1)"
  cd /kbuild/driver-610/NVIDIA-Linux-aarch64-$DRIVER_VER/kernel-open
  make clean >/dev/null 2>&1 || true
  make -j"$(nproc)" SYSSRC=/kbuild/linux-$KVER modules
' > "$LOG" 2>&1
RC=$?
echo "container build rc=$RC"
echo "=== tail ==="; tail -20 "$LOG"
echo "=== .ko produced? ==="; ls -la "$KO"/*.ko 2>/dev/null || { echo "(no .ko) — FAIL"; exit 1; }
echo "=== Unknown symbol / hard errors (carried-patch territory) ==="
grep -iE "unknown symbol|error:|undefined reference" "$LOG" | head -25 || echo "(none)"
echo "=== vermagic (MUST be exactly $EXPECT_VM) ==="
FAIL=0
for m in nvidia.ko nvidia-uvm.ko nvidia-modeset.ko nvidia-drm.ko; do
  if [ -f "$KO/$m" ]; then
    VM=$(modinfo -F vermagic "$KO/$m" 2>/dev/null | awk '{print $1}')
    echo "$m -> $VM"
    [ "$VM" = "$EXPECT_VM" ] || FAIL=1
  fi
done
if [ "$RC" = 0 ] && [ "$FAIL" = 0 ]; then echo "BUILD-OPEN-OK $EXPECT_VM"; else echo "BUILD-OPEN-FAIL rc=$RC vermagic_mismatch=$FAIL"; exit 1; fi
