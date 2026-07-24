#!/bin/bash
# spark-rocky repo test suite — runnable on ANY machine (no GB10 needed), so it can gate CI.
# Two machine-independent layers: (1) every shell script parses (bash -n); (2) behavioral INVARIANTS this
# codebase must hold — the suffix-drop stays done, the debug-hatch path is script-relative, zstd is gated,
# the doctor is self-contained, versions.env is well-formed. The hardware-dependent proof (real GPU, real
# boot) lives in validate.sh, which runs ON the box. Run: make test  (or bash tests/run-tests.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  PASS: $1"; }
no(){ fail=$((fail+1)); echo "  FAIL: $1"; }

echo "== syntax: every shell script parses (bash -n) =="
while IFS= read -r f; do
  if err=$(bash -n "$f" 2>&1); then ok "$f"; else no "$f"; echo "        $err"; fi
done < <(find scripts tests -name '*.sh' | sort)

echo
echo "== invariants: properties this codebase must hold (machine-independent) =="
source config/versions.env
[[ "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]     && ok "versions.env: KVER is x.y.z ($KVER)"            || no "versions.env: KVER malformed ($KVER)"
[[ "$PAGE_SIZE" == 4k || "$PAGE_SIZE" == 64k ]] && ok "versions.env: PAGE_SIZE is 4k|64k ($PAGE_SIZE)" || no "versions.env: PAGE_SIZE invalid ($PAGE_SIZE)"
[[ "$KERNEL_SHA256" =~ ^[0-9a-f]{64}$ ]]      && ok "versions.env: KERNEL_SHA256 is 64 hex"          || no "versions.env: KERNEL_SHA256 malformed"
[[ "$DRIVER_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "versions.env: DRIVER_VER is x.y.z ($DRIVER_VER)" || no "versions.env: DRIVER_VER malformed ($DRIVER_VER)"
[[ "$DRIVER_SHA256" =~ ^[0-9a-f]{64}$ ]]      && ok "versions.env: DRIVER_SHA256 is 64 hex"          || no "versions.env: DRIVER_SHA256 malformed"
[[ "$KERNEL_SOURCE" == kernelorg || "$KERNEL_SOURCE" == clk ]] && ok "versions.env: KERNEL_SOURCE is kernelorg|clk ($KERNEL_SOURCE)" || no "versions.env: KERNEL_SOURCE invalid ($KERNEL_SOURCE)"
[ -f "$KCONFIG" ]                             && ok "versions.env: KCONFIG points at a real base config" || no "versions.env: KCONFIG missing ($KCONFIG)"
[[ "$CLK_COMMIT" =~ ^[0-9a-f]{40}$ ]]        && ok "versions.env: CLK_COMMIT is a 40-hex SHA ($CLK_COMMIT)" || no "versions.env: CLK_COMMIT malformed ($CLK_COMMIT)"
vmaj(){ echo "v${1%%.*}.x"; }; if [ "$(vmaj 6.18.35)" = v6.x ] && [ "$(vmaj 7.0.0)" = v7.x ]; then ok "kernel.org v-major derivation (6.18->v6.x, 7.0->v7.x)"; else no "v-major derivation wrong"; fi
# 01 dispatches the kernel source + derives the v-major path (no hardcoded v6.x) -- the "move kernels" pre-work.
if grep -qF 'KERNEL_SOURCE' scripts/01-build-kernel.sh && grep -qF 'v${KVER%%.*}.x' scripts/01-build-kernel.sh; then ok "01 has the kernel-source dispatch + derived v-major path"; else no "01 missing the kernel-source dispatch / v-major derivation"; fi
# 01 writes build.env with the resolved KVER; downstream scripts (02/02b/03/04) source it so CLK-derived KVER propagates.
if grep -qF 'build.env' scripts/01-build-kernel.sh; then ok "01 writes build.env with resolved KVER"; else no "01 does not write build.env"; fi
for s in 02-build-rootfs.sh 02b-install-gpu-docker.sh 03-build-nvidia-open.sh 04-build-image.sh; do
  if grep -qF 'build.env' "scripts/$s"; then ok "$s sources build.env"; else no "$s missing build.env source (CLK KVER would not propagate)"; fi
done
# build.env is stale-gated: 01 stamps source+commit; every downstream consumer fails closed on a mismatch.
if grep -qF 'BUILD_KERNEL_SOURCE=$KERNEL_SOURCE' scripts/01-build-kernel.sh && grep -qF 'BUILD_CLK_COMMIT' scripts/01-build-kernel.sh; then ok "01 stamps build.env with source + CLK commit"; else no "01 build.env missing the source/commit stamps"; fi
for s in 02-build-rootfs.sh 02b-install-gpu-docker.sh 03-build-nvidia-open.sh 04-build-image.sh; do
  if grep -qF 'stale build.env' "scripts/$s"; then ok "$s fails closed on a stale build.env"; else no "$s does not gate build.env staleness"; fi
done
# The signing/cert neutralization applies to BOTH kernel sources (the CLK configs carry MODULE_SIG=y +
# the default key path — a tarball build would embed an ephemeral cert = nondeterministic Image bytes).
if grep -qF 'Neutralize distro signing/cert baggage on BOTH paths' scripts/01-build-kernel.sh; then ok "01 neutralizes signing baggage on both kernel sources"; else no "01 signing neutralization is not both-paths"; fi
if grep -qF -- '--disable MODULE_SIG_ALL' scripts/01-build-kernel.sh; then ok "01 disables MODULE_SIG_ALL explicitly (CLK decouples it from MODULE_SIG)"; else no "01 missing the MODULE_SIG_ALL disable — CLK modules_install SIGN step dies on the empty key"; fi
# The kernel-as-RPM pipeline (#59): 01 builds a STRIPPED kernel rpm and fails closed if none is produced;
# 02 dnf-installs it into the rootfs (rpm db truthful) with %post skipped (we own boot plumbing) and the
# %post file copies replicated; upgrade-metal installs via dnf on the metal and re-carries the nvidia
# extra/ tree (the rpm ships only the kernel's own modules — losing extra/ = losing the GPU driver).
if grep -qE 'INSTALL_MOD_STRIP=1 binrpm-pkg' scripts/01-build-kernel.sh; then ok "01 builds the kernel rpm stripped (binrpm-pkg, #59)"; else no "01 missing INSTALL_MOD_STRIP=1 binrpm-pkg — unstripped rpm is ~1.5G (#59)"; fi
if grep -qF 'binrpm-pkg produced no kernel rpm' scripts/01-build-kernel.sh; then ok "01 fails closed when binrpm-pkg produces no rpm (#59)"; else no "01 does not fail closed on a missing kernel rpm (#59)"; fi
if grep -qF 'echo "KRPM=$KRPM"' scripts/01-build-kernel.sh; then ok "01 hands KRPM to downstream via build.env (#59)"; else no "01 does not persist KRPM in build.env (#59)"; fi
for s in 02-build-rootfs.sh upgrade-metal.sh; do
  if grep -qF 'KRPM not set' "scripts/$s"; then ok "$s fails closed when build.env lacks KRPM (#59)"; else no "$s does not gate a pre-rpm build.env (#59)"; fi
  if grep -qF 'tsflags=noscripts' "scripts/$s"; then ok "$s skips the rpm %post (we own boot plumbing) (#59)"; else no "$s runs the rpm %post — kernel-install/BLS would fight our static GRUB (#59)"; fi
  if grep -qE 'for f in vmlinuz System.map config' "scripts/$s"; then ok "$s replicates the skipped %post file copies (#59)"; else no "$s misses the %post vmlinuz/System.map/config copies (#59)"; fi
done
if grep -qE 'rpm --root "\$R" -q kernel' scripts/02-build-rootfs.sh; then ok "02 verifies the kernel landed in the image rpm database (#59)"; else no "02 does not verify the image rpm db knows the kernel (#59)"; fi
if grep -qF 'rm -rf "/lib/modules/$KVER/extra"' scripts/upgrade-metal.sh && grep -qF 'rootfs/lib/modules/$KVER/extra" "/lib/modules/$KVER/extra"' scripts/upgrade-metal.sh; then ok "upgrade-metal re-carries the nvidia extra/ tree after the rpm install (#59)"; else no "upgrade-metal kernel path sheds the GPU driver — the rpm carries no extra/ (#59)"; fi
if grep -qF 'kernel_rpm=' scripts/05-package-image.sh; then ok "05 stamps the kernel NEVRA into the image provenance (#59)"; else no "05 provenance carries no kernel NEVRA (#59)"; fi
if grep -qF 'kernel present in the image rpm database' scripts/05-package-image.sh; then ok "05 fails closed if the image rpm db lacks the kernel (#59)"; else no "05 does not gate the image rpm db (#59)"; fi
# The rpm is a SERVED, ATTESTED artifact: 05 vends it fail-closed, 06's signed CHECKSUM covers *.rpm,
# 07 binds served rpm <-> manifest <-> signature (skipping pre-rpm manifests, not failing them).
if grep -qF 'kernel rpm missing (KRPM=' scripts/05-package-image.sh; then ok "05 vends the kernel rpm fail-closed (#59)"; else no "05 does not vend the kernel rpm (#59)"; fi
if grep -qF 'kernel_rpm_sha256' scripts/05-package-image.sh; then ok "05 manifest carries the kernel rpm sha256 (#59)"; else no "05 manifest lacks the rpm sha — 07 cannot bind it (#59)"; fi
if grep -qE 'ARTS=\(.*\*\.rpm' scripts/06-sign-release.sh; then ok "06 signed CHECKSUM covers *.rpm (#59)"; else no "06 CHECKSUM does not cover the kernel rpm (#59)"; fi
if grep -qF 'kernel_rpm_sha256' scripts/07-verify-release.sh && grep -qF 'predates the rpm pipeline' scripts/07-verify-release.sh; then ok "07 verifies the served rpm against the signed CHECKSUM (pre-rpm manifests skip) (#59)"; else no "07 does not verify the served kernel rpm (#59)"; fi
if grep -qF 'kernel present in the rpm database' scripts/validate.sh; then ok "doctor checks rpm -q kernel on the booted box (#59)"; else no "doctor does not check the rpm database (#59)"; fi
# 01's build container must carry the binrpm build deps (rpm-build/cpio/kmod/openssl-the-binary).
if grep -qE 'rpm-build cpio kmod' scripts/01-build-kernel.sh; then ok "01 installs the binrpm-pkg build deps (#59)"; else no "01 container lacks rpm-build/cpio/kmod — binrpm-pkg dies (#59)"; fi
# The uname doctrine, refined 2026-07-17: uname carries SOURCE LINEAGE ("-clk", distro convention),
# NEVER config properties (the 64k-suffix ban stays). Exactly ONE LOCALVERSION site is allowed: 01's
# clk branch setting "-clk". No KREL variable — KVER itself is the derived kernel release.
if [ "$(grep -rcF -- '--set-str LOCALVERSION "-clk"' scripts/01-build-kernel.sh)" = 1 ]; then ok "01 sets the clk lineage suffix (LOCALVERSION=-clk, exactly once)"; else no "01 missing/duplicated the clk LOCALVERSION lineage suffix"; fi
if grep -rF -- '--set-str LOCALVERSION' scripts/ | grep -vF '"-clk"' | grep -q .; then no "a non-lineage LOCALVERSION crept in (config properties must stay out of uname)"; else ok "no non-lineage LOCALVERSION in any script"; fi
if grep -qw 'KREL' scripts/*.sh;             then no "KREL variable reintroduced (KVER is the derived kernel release)"; else ok "no KREL variable in any build script"; fi
# KVER becomes the DERIVED release post-olddefconfig (kernelrelease), and 05/upgrade-metal consume it
# through the stale-gated build.env like the rest of the pipeline.
if grep -qF 'make -s kernelrelease' scripts/01-build-kernel.sh; then ok "01 derives KVER from make kernelrelease"; else no "01 does not derive the kernel release"; fi
for s in 05-package-image.sh upgrade-metal.sh; do
  if grep -qF 'stale build.env' "scripts/$s"; then ok "$s fails closed on a stale build.env"; else no "$s does not gate build.env staleness"; fi
done
if grep -qF 'kernel_source=${KERNEL_SOURCE}' scripts/05-package-image.sh; then ok "05 stamps kernel_source + clk_commit provenance"; else no "05 provenance missing the kernel source"; fi
if grep -qF 'ciq-6.18.y' scripts/drift-check.sh && grep -qF 'row CLK' scripts/drift-check.sh; then ok "drift-check: CLK branch tip is the trigger row"; else no "drift-check missing the CLK trigger row"; fi
# Serve gate (#67): exists, fails closed on a dead container, and is a documented pre-sign release step.
if [ -f scripts/serve-gate.sh ] && grep -qF 'GATE-PASS' scripts/serve-gate.sh && grep -qF 'GATE-FAIL' scripts/serve-gate.sh; then ok "serve-gate.sh present + pass/fail-closed (#67)"; else no "serve-gate.sh missing or not fail-closed (#67)"; fi
if grep -qF 'serve-gate.sh' docs/build/release.md; then ok "release runbook requires the serve gate pre-sign (#67)"; else no "release.md does not mandate the serve gate (#67)"; fi
# 02 ships the MT7925 WiFi/BT firmware uncompressed into the rootfs (#64) — the shipped image had none.
if grep -qF 'mediatek/mt7925' scripts/02-build-rootfs.sh && grep -qF 'zstd -d' scripts/02-build-rootfs.sh; then ok "02 ships MT7925 firmware uncompressed (#64)"; else no "02 missing the MT7925 firmware step (#64)"; fi
# Debug hatch reads the script-relative config (the W-vs-HERE bug that silently skipped baking it).
if grep -qF 'HERE/../config/debug-authorized_keys' scripts/04-build-image.sh && ! grep -qF 'W/config/debug-authorized_keys' scripts/04-build-image.sh; then ok "04 debug hatch reads HERE/../config (not W/config)"; else no "04 debug hatch path bug present"; fi
# zstd is gated + content-verified, not silently swallowed (#44).
if grep -qF 'command -v zstd' scripts/04-build-image.sh; then ok "04 gates zstd presence before dracut (#44)"; else no "04 missing the zstd presence gate (#44)"; fi
if grep -qF '28b52ffd' scripts/04-build-image.sh;          then ok "04 verifies initramfs is zstd by magic bytes (#44)"; else no "04 missing the zstd compression content-check (#44)"; fi
if grep -qF 'resolv.conf' scripts/04-build-image.sh;       then ok "04 gives the chroot DNS (resolv.conf — #44 root cause)"; else no "04 chroot has no resolv.conf — chroot dnf will fail (#44)"; fi
if grep -qF 'omit-drivers "mlx5' scripts/04-build-image.sh; then ok "04 omits mlx5 from the initramfs (no early coldplug load, #30)"; else no "04 does not omit mlx5 — it coldplug-loads in the initramfs (#30)"; fi
if grep -qF 'fbcon=nodefer' scripts/04-build-image.sh;      then ok "04 cmdline has fbcon=nodefer (no late console-takeover glitch)"; else no "04 missing fbcon=nodefer (autologin/console blank glitch)"; fi
# Driver .run supply-chain gate: both consumers verify against the pinned DRIVER_SHA256, fail-closed (#58).
if grep -qF 'DRIVER_SHA256' scripts/02b-install-gpu-docker.sh && grep -qF 'refusing to extract' scripts/02b-install-gpu-docker.sh; then ok "02b verifies the .run against pinned DRIVER_SHA256 before extract"; else no "02b missing the .run sha256 gate"; fi
if grep -qF 'DRIVER_SHA256' scripts/02c-driver-userspace.sh && grep -qF 'refusing to install' scripts/02c-driver-userspace.sh; then ok "02c verifies the .run against pinned DRIVER_SHA256 before install"; else no "02c missing the .run sha256 gate"; fi
# The doctor is self-contained: no dependency on a sibling proof-of-life.sh.
if grep -qF 'proof-of-life' scripts/validate.sh; then no "validate.sh still depends on proof-of-life.sh (must be self-contained)"; else ok "validate.sh is self-contained (inlines its own CUDA proof)"; fi
# Page-size -> config-symbol mapping (what 05's fail-closed page-size gate keys on).
pgsym(){ [ "$1" = 64k ] && echo CONFIG_ARM64_64K_PAGES=y || echo CONFIG_ARM64_4K_PAGES=y; }
if [ "$(pgsym 64k)" = CONFIG_ARM64_64K_PAGES=y ] && [ "$(pgsym 4k)" = CONFIG_ARM64_4K_PAGES=y ]; then ok "page-size->config-symbol mapping correct"; else no "page-size->config-symbol mapping wrong"; fi
# Doctor has no hardcoded issue URL (S1).
if grep -qF 'issues/new' scripts/validate.sh; then no "validate.sh still prints a hardcoded issue URL (S1)"; else ok "validate.sh has no hardcoded issue URL (S1)"; fi
# 04 grub menuentry is generated ONCE (S2) — guards against the two-copies divergence returning.
if [ "$(grep -cF "menuentry 'Rocky" scripts/04-build-image.sh)" = 1 ]; then ok "04 grub menuentry single-sourced (S2)"; else no "04 grub menuentry duplicated again (S2)"; fi
# 04 verifies the debug hatch was actually baked, in-build (S4/B2).
if grep -qF 'debug-enable.sh not baked' scripts/04-build-image.sh; then ok "04 verifies the debug hatch was baked (S4)"; else no "04 does not verify the debug hatch was baked (S4)"; fi
# install-baremetal: match removable USB (not a hardcoded device), and abort on a failed rsync (S5).
if grep -qF '"/dev/sda2"' scripts/install-baremetal.sh; then no "install-baremetal hardcodes /dev/sda2 (S5)"; else ok "install-baremetal matches removable USB, not /dev/sda2 (S5)"; fi
if grep -qF 'rsync to the NVMe failed' scripts/install-baremetal.sh; then ok "install-baremetal aborts on a failed rsync (S5)"; else no "install-baremetal does not act on the rsync rc (S5)"; fi
# proof-of-life clears the stale binary so a failed recompile cannot report a false PASS.
if grep -qF 'rm -f /tmp/vectoradd' scripts/proof-of-life.sh; then ok "proof-of-life clears the stale binary (no false PASS)"; else no "proof-of-life can report a stale-binary false PASS"; fi
# No stale "watchdog" coverage claim in CI/Makefile (#25 was removed, S7).
if grep -riq watchdog .github/ Makefile; then no "stale watchdog claim in CI/Makefile (#25 removed, S7)"; else ok "no stale watchdog claim in CI/Makefile (S7)"; fi
# Garbage-collected cruft stays gone (the bringup scripts + the 362 KB stock-DGX config).
if [ -e scripts/bringup ] || [ -e config/dgx-6.17-nvidia.config ]; then no "GC'd cruft reappeared (bringup/ or dgx-6.17 config)"; else ok "GC'd cruft stays gone (bringup, dgx-6.17 config)"; fi
# Benchmark runner fails closed on a ragged/partial sweep (#42); the grid-check concurrency set must mirror the --concurrency arg.
if grep -qF 'ragged concurrency grid' scripts/run-benchmark-matrix.sh; then ok "run-benchmark-matrix fails closed on an incomplete grid (#42)"; else no "run-benchmark-matrix missing the grid-completeness check (#42)"; fi
arg_c=$(grep -oE -- '--concurrency [0-9 ]+' scripts/run-benchmark-matrix.sh | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')
want_c=$(grep -oE 'want\["[0-9]+"\]' scripts/run-benchmark-matrix.sh | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')
if [ -n "$arg_c" ] && [ "$arg_c" = "$want_c" ]; then ok "#42 grid-check want{} matches --concurrency arg ($arg_c)"; else no "#42 grid-check want{} ($want_c) != --concurrency ($arg_c)"; fi
# 04 pins a FIXED ESP partition GUID so a USB-first firmware boot entry survives re-flashes (#47).
if grep -qF 'sfdisk --part-uuid "$IMG" 1 A84952EE-452B-44B3-ACB5-B036BA8E6B0D' scripts/04-build-image.sh; then ok "04 pins the fixed ESP GUID via sfdisk (#47/#60)"; else no "04 missing the sfdisk ESP GUID pin (#47/#60)"; fi
if grep -qF 'ESP GUID read-back mismatch' scripts/04-build-image.sh; then ok "04 verifies the GUID pin by read-back, fail-closed (#60)"; else no "04 GUID pin not verified (#60 fail-open class)"; fi
if grep -rqE '^[^#]*\bsgdisk\b' scripts/; then no "sgdisk still INVOKED in scripts/ (#60 — gdisk is uninstallable on the metal)"; else ok "no sgdisk invocation anywhere in scripts/ (comments exempt, #60)"; fi
# Post-hoc throttle integrity (#43): templog captures the signal, the detector fails closed, the runner consumes it, the image bakes it.
if grep -qF 'thermal_slowdown' scripts/templog.sh; then ok "templog captures the throttle signal (thermal_slowdown, #43)"; else no "templog missing the throttle signal (#43)"; fi
if [ -f scripts/check-throttle.sh ] && grep -qF 'THROTTLED' scripts/check-throttle.sh; then ok "check-throttle.sh present + fails closed on a throttled run (#43)"; else no "check-throttle.sh missing or not fail-closed (#43)"; fi
if grep -qF 'check-throttle.sh' scripts/run-benchmark-matrix.sh; then ok "run-benchmark-matrix consumes the throttle check (#43, composes with #42)"; else no "run-benchmark-matrix does not call check-throttle (#43)"; fi
if grep -qF 'check-throttle.sh' scripts/04-build-image.sh; then ok "04 bakes check-throttle.sh into the image (#43)"; else no "04 does not bake check-throttle.sh (#43)"; fi
# Install-to-metal paths (#34): a NON-destructive in-place upgrade + a typed-confirm-guarded wipe; the wiper is NOT baked into the image.
if [ -f scripts/upgrade-metal.sh ] && ! grep -qE 'wipefs|mklabel|mkfs\.' scripts/upgrade-metal.sh; then ok "upgrade-metal.sh present + non-destructive (no wipe/format, #34)"; else no "upgrade-metal.sh missing or it wipes/formats (#34)"; fi
# upgrade-metal dispatches on what differs — kernel, driver-only, or refuses when both are current.
if grep -qF 'driver-only' scripts/upgrade-metal.sh && grep -qF 'nothing to upgrade' scripts/upgrade-metal.sh; then ok "upgrade-metal dispatches kernel/driver-only/nothing"; else no "upgrade-metal missing the driver-only dispatch"; fi
if grep -qF 'DRIVER_SHA256' scripts/upgrade-metal.sh && grep -qF 'refusing to install' scripts/upgrade-metal.sh; then ok "upgrade-metal sha256-gates the .run userspace install"; else no "upgrade-metal does not gate the .run against DRIVER_SHA256"; fi
if grep -q 'nvidia-drm.modeset=0' scripts/upgrade-metal.sh && grep -q 'fbcon=nodefer' scripts/upgrade-metal.sh; then ok "upgrade-metal carries the 04 boot-hygiene cmdline (#34)"; else no "upgrade-metal missing the boot-hygiene cmdline (#34)"; fi
if grep -qF 'WIPE $TGT' scripts/install-baremetal.sh; then ok "install-baremetal requires a typed WIPE confirmation (#34)"; else no "install-baremetal has no typed-confirmation guard (#34)"; fi
if grep -qF 'install-baremetal.sh' scripts/04-build-image.sh; then no "the NVMe wiper is baked into the image — must stay a separate path (#34)"; else ok "the NVMe wiper is NOT baked into the image (#34)"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
