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
[[ "${DRIVER_BRANCH:-}" =~ ^[0-9]+$ ]]        && ok "versions.env: DRIVER_BRANCH is numeric ($DRIVER_BRANCH)" || no "versions.env: DRIVER_BRANCH missing/malformed (#83)"
[[ "$DRIVER_VER" == "$DRIVER_BRANCH".* ]]     && ok "versions.env: DRIVER_VER is on DRIVER_BRANCH ($DRIVER_BRANCH)" || no "versions.env: DRIVER_VER not on the pinned branch — bump DRIVER_BRANCH deliberately (#83)"
grep -q 'DRIVER_BRANCH' scripts/drift-check.sh && grep -q 'human' scripts/drift-check.sh && ok "drift-check tracks the pinned driver branch; cross-branch is INFO (#83)" || no "drift-check is branch-agnostic — the #80 walk-on class is open again (#83)"
grep -q 'ORPHAN_WINDOW_DAYS' scripts/drift-check.sh && grep -q 'ORPHANED' scripts/drift-check.sh && ok "drift-check carries the branch-orphan tripwire (WARN + drift exit, #83)" || no "drift-check has no orphan tripwire — silent branch death is undetected (#83)"
if [ -f docs/build/branch-transition.md ] && grep -q 'no-install-libglvnd' docs/build/branch-transition.md && grep -qi 'step 0' docs/build/branch-transition.md; then ok "the branch-transition runbook exists with the A/B-first rule + the glvnd landmine (#83)"; else no "branch-transition runbook missing or gutted (#83)"; fi
grep -q '#1269 REPRODUCER' docs/build/build.md && ok "the per-bump #1269 reproducer is a written bump-flow step (#83/#65)" || no "the reproducer step is a promise, not a written step (#83)"
[[ "$KERNEL_SOURCE" == kernelorg || "$KERNEL_SOURCE" == clk ]] && ok "versions.env: KERNEL_SOURCE is kernelorg|clk ($KERNEL_SOURCE)" || no "versions.env: KERNEL_SOURCE invalid ($KERNEL_SOURCE)"
[ -f "$KCONFIG" ]                             && ok "versions.env: KCONFIG points at a real base config" || no "versions.env: KCONFIG missing ($KCONFIG)"
[[ "$CLK_COMMIT" =~ ^[0-9a-f]{40}$ ]]        && ok "versions.env: CLK_COMMIT is a 40-hex SHA ($CLK_COMMIT)" || no "versions.env: CLK_COMMIT malformed ($CLK_COMMIT)"
# 01 dispatches the kernel source + derives the v-major path (no hardcoded v6.x) -- the "move kernels" pre-work.
# (The old local-function vmaj self-test was a tautology — audit #70 C6; the grep below tests the real code.)
if grep -qF 'KERNEL_SOURCE' scripts/01-build-kernel.sh && grep -qF 'v${KVER%%.*}.x' scripts/01-build-kernel.sh; then ok "01 has the kernel-source dispatch + derived v-major path"; else no "01 missing the kernel-source dispatch / v-major derivation"; fi
# 01 writes build.env with the resolved KVER; downstream scripts (02/02b/03/04) source it so CLK-derived KVER propagates.
if grep -qF 'build.env' scripts/01-build-kernel.sh; then ok "01 writes build.env with resolved KVER"; else no "01 does not write build.env"; fi
for s in 02-build-rootfs.sh 02b-install-gpu-docker.sh 03-build-nvidia-open.sh 04-build-image.sh; do
  if grep -qF 'build.env' "scripts/$s"; then ok "$s sources build.env"; else no "$s missing build.env source (CLK KVER would not propagate)"; fi
done
# build.env is stale-gated: 01 stamps source+commit; every downstream consumer fails closed on a mismatch.
if grep -qF 'BUILD_KERNEL_SOURCE=$KERNEL_SOURCE' scripts/01-build-kernel.sh && grep -qF 'BUILD_CLK_COMMIT' scripts/01-build-kernel.sh; then ok "01 stamps build.env with source + CLK commit"; else no "01 build.env missing the source/commit stamps"; fi
# THIRD_PARTY.md is AI-maintainable BY CONSTRUCTION: prose never carries a pin (inline SHAs in the
# roster rotted twice in the week of 2026-07-24) — volatile coordinates live in the env files, and the
# registry maps input -> role -> pin location. The release runbook carries the maintenance protocol.
if grep -qE '[0-9a-f]{12,40}|sha256[:]' THIRD_PARTY.md; then no "THIRD_PARTY.md carries an inline pin value — pins live in env files only"; else ok "THIRD_PARTY.md carries no pin values (prose-pin rule)"; fi
if grep -qF 'config/versions.env' THIRD_PARTY.md && grep -qF 'config/serving-images.env' THIRD_PARTY.md; then ok "THIRD_PARTY.md points at both authoritative pin files"; else no "THIRD_PARTY.md missing a pin-file pointer"; fi
if grep -qF 'Maintenance protocol' THIRD_PARTY.md; then ok "THIRD_PARTY.md carries its own maintenance protocol"; else no "THIRD_PARTY.md has no maintenance protocol — not AI-maintainable"; fi
if grep -qF 'THIRD_PARTY.md' docs/build/build.md; then ok "release runbook runs the third-party currency check at cut"; else no "release runbook missing the THIRD_PARTY.md currency step"; fi

# Script-review hardening (2026-07-23 Gafton pass): absent build.env is FATAL (M2), 06 refuses an
# ambiguous vend dir (M8 — two images would let flash.sh pick the older one with a valid signature),
# 07 pins the release fingerprint (any-key "Good signature" is not ours) and evals no served data (M9).
if grep -qF 'no $W/build.env' scripts/lib/build-env-gate.sh; then ok "build-env gate: ABSENT is as fatal as stale (M2)"; else no "build-env gate fails open when build.env is absent (M2)"; fi
if grep -qF 'one release per vend dir' scripts/06-sign-release.sh; then ok "06 refuses to sign an ambiguous vend dir (M8)"; else no "06 signs whatever is lying in vend/ (M8)"; fi
if grep -qF 'VALIDSIG $FPR' scripts/07-verify-release.sh; then ok "07 pins the release-key fingerprint (MINOR-7)"; else no "07 accepts any Good signature (MINOR-7)"; fi
if grep -qE '^chk\(\)\{ if eval' scripts/07-verify-release.sh; then no "07 evals served-manifest data (M9 — injection in the verifier)"; else ok "07 evals no served data (M9)"; fi
if grep -qF 'FATAL: KERNEL_SHA256 pin missing' scripts/01-build-kernel.sh; then ok "01 refuses an empty KERNEL_SHA256 pin (M4)"; else no "01 silently skips tarball verification on an empty pin (M4)"; fi
if grep -qF 'MODULE_SIG still enabled after neutralization' scripts/01-build-kernel.sh && grep -qF 'FW_LOADER_COMPRESS_ZSTD did not take' scripts/01-build-kernel.sh; then ok "01 fail-closed asserts the two mine-adjacent config edits (M3)"; else no "01 config edits can silently no-op onto documented mines (M3)"; fi

# One gate implementation (audit #70 C1): the lib carries the real checks; every consumer sources it.
for c in 'BUILD_KERNEL_SOURCE:-}" = "$KERNEL_SOURCE"' 'KVER $KVER != pinned $PIN_KVER' 'CLK_COMMIT moved'; do
  if grep -qF "$c" scripts/lib/build-env-gate.sh; then ok "build-env-gate lib carries the check: ${c:0:30}"; else no "build-env-gate lib missing a staleness check: ${c:0:30}"; fi
done
for s in 02-build-rootfs.sh 02b-install-gpu-docker.sh 03-build-nvidia-open.sh 04-build-image.sh 05-package-image.sh upgrade-metal.sh; do
  if grep -qF 'source "$HERE/lib/build-env-gate.sh"' "scripts/$s"; then ok "$s sources the one build-env gate"; else no "$s does not source the build-env gate (C1)"; fi
  if grep -qF 'stale build.env' "scripts/$s"; then no "$s carries a private copy of the gate — C1 consolidated it"; else ok "$s carries no private gate copy"; fi
done
# The signing/cert neutralization applies to BOTH kernel sources (the CLK configs carry MODULE_SIG=y +
# the default key path — a tarball build would embed an ephemeral cert = nondeterministic Image bytes).
if grep -qF -- '--set-str SYSTEM_TRUSTED_KEYS ""' scripts/01-build-kernel.sh && grep -qF -- '--disable SECURITY_LOCKDOWN_LSM' scripts/01-build-kernel.sh; then ok "01 neutralizes signing/cert baggage (real invocation, not the comment — C6)"; else no "01 signing neutralization commands missing"; fi
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
# The kernel rpm carries no extra/ — the open .ko set must arrive via the kmod rpm on BOTH dispatch
# paths, or a kernel bump silently sheds the GPU driver (#59 -> #77).
if [ "$(grep -c 'install_kmod_rpm$' scripts/upgrade-metal.sh)" -ge 2 ] && grep -qF 'KMODRPM not set' scripts/upgrade-metal.sh; then ok "upgrade-metal installs the kmod rpm on both dispatch paths, fail-closed (#77)"; else no "upgrade-metal kernel path sheds the GPU driver — kmod rpm not installed on both paths (#77)"; fi
if grep -qF 'kernel_rpm=' scripts/05-package-image.sh; then ok "05 stamps the kernel NEVRA into the image provenance (#59)"; else no "05 provenance carries no kernel NEVRA (#59)"; fi
if grep -qF 'kernel present in the image rpm database' scripts/05-package-image.sh; then ok "05 fails closed if the image rpm db lacks the kernel (#59)"; else no "05 does not gate the image rpm db (#59)"; fi
# The rpm is a SERVED, ATTESTED artifact: 05 vends it fail-closed, 06's signed CHECKSUM covers *.rpm,
# 07 binds served rpm <-> manifest <-> signature (skipping pre-rpm manifests, not failing them).
if grep -qF 'kernel rpm missing (KRPM=' scripts/05-package-image.sh; then ok "05 vends the kernel rpm fail-closed (#59)"; else no "05 does not vend the kernel rpm (#59)"; fi
if grep -qF 'kernel_rpm_sha256' scripts/05-package-image.sh; then ok "05 manifest carries the kernel rpm sha256 (#59)"; else no "05 manifest lacks the rpm sha — 07 cannot bind it (#59)"; fi
if grep -qE 'ARTS=\(.*\*\.rpm' scripts/06-sign-release.sh; then ok "06 signed CHECKSUM covers *.rpm (#59)"; else no "06 CHECKSUM does not cover the kernel rpm (#59)"; fi
if grep -qF 'kernel_rpm_sha256' scripts/07-verify-release.sh && grep -qF 'predates the rpm pipeline' scripts/07-verify-release.sh; then ok "07 verifies the served rpm against the signed CHECKSUM (pre-rpm manifests skip) (#59)"; else no "07 does not verify the served kernel rpm (#59)"; fi
if grep -qF 'kernel present in the rpm database' scripts/validate.sh; then ok "doctor checks rpm -q kernel on the booted box (#59)"; else no "doctor does not check the rpm database (#59)"; fi
if grep -qF 'cudaMallocManaged(&p,n)' scripts/validate.sh && grep -qF '8ull<<30' scripts/validate.sh; then ok "doctor runs the 8 GiB managed-memory check (#63 — the #65-class detector)"; else no "doctor missing the managed-memory check (#63)"; fi
# #77: the NVIDIA stack is rpm-owned — 02b packages + dnf-installs the kmod rpm (kver in the NAME,
# kernel-package-style coexistence), 02c snapshots the .run install and packages the payload diff as
# the userspace rpm; both vended by 05, bound by 07, checked by the doctor.
if grep -qE 'Name: kmod-nvidia-open-\$KSAN' scripts/02b-install-gpu-docker.sh; then ok "02b packages the open .ko set as a kmod rpm (kver in the Name) (#77)"; else no "02b does not build the kmod rpm (#77)"; fi
if grep -qF 'kmod rpm not in rootfs rpm db' scripts/02b-install-gpu-docker.sh; then ok "02b fail-closed verifies the kmod rpm landed in the rootfs db (#77)"; else no "02b does not verify the kmod rpm install (#77)"; fi
if grep -qF 'comm -13 /tmp/pre.list /tmp/post.list' scripts/02c-driver-userspace.sh; then ok "02c packages the .run payload from the install path-diff (ground truth) (#77)"; else no "02c does not snapshot-package the userspace (#77)"; fi
if grep -qF 'nvidia-smi not rpm-owned' scripts/02c-driver-userspace.sh; then ok "02c fail-closed verifies the userspace is rpm-owned (#77)"; else no "02c does not verify userspace rpm ownership (#77)"; fi
# glvnd is DISTRO property: pre-snapshot dnf install + no --install-libglvnd, or the userspace rpm
# swallows the dispatch libs and conflicts with libglvnd-* on any normal host (hit on the metal).
if grep -qE 'libglvnd-egl libglvnd-glx libglvnd-opengl' scripts/02c-driver-userspace.sh && ! grep -qF -- '--install-libglvnd' scripts/02c-driver-userspace.sh; then ok "02c: glvnd from Rocky rpms, not the .run — the userspace rpm carries NVIDIA bytes only (#77)"; else no "02c userspace rpm would swallow glvnd and conflict on normal hosts (#77)"; fi
if grep -qF 'USRPM' scripts/05-package-image.sh && grep -qF 'KMODRPM' scripts/05-package-image.sh; then ok "05 vends the kmod + userspace rpms with sha256 manifest lines (#77)"; else no "05 does not vend the #77 rpms"; fi
if grep -qF 'userspace_rpm_sha256' scripts/07-verify-release.sh; then ok "07 binds served kmod/userspace rpms to the signed CHECKSUM (#77)"; else no "07 does not verify the #77 rpms"; fi
if grep -qF 'rsuffix="${TAG##*-}"' scripts/07-verify-release.sh && ! grep -qF '$GS cat "$BUCKET"/*BUILD-MANIFEST.txt' scripts/07-verify-release.sh; then ok "07 derives the manifest name from the tag; bare bucket wildcard gone (#78)"; else no "07 still reads the manifest via a bare bucket wildcard (#78)"; fi
if grep -qF 'kmod-nvidia-open-$(uname -r | tr - _)' scripts/validate.sh; then ok "doctor checks the NVIDIA stack is rpm-owned (#77)"; else no "doctor missing the #77 rpm-ownership checks"; fi
# 01's build container must carry the binrpm build deps (rpm-build/cpio/kmod/openssl-the-binary).
if grep -qE 'rpm-build cpio kmod' scripts/01-build-kernel.sh; then ok "01 installs the binrpm-pkg build deps (#59)"; else no "01 container lacks rpm-build/cpio/kmod — binrpm-pkg dies (#59)"; fi
# The uname doctrine, refined 2026-07-17: uname carries SOURCE LINEAGE ("-clk", distro convention),
# NEVER config properties (the 64k-suffix ban stays). Exactly ONE LOCALVERSION site is allowed: 01's
# clk branch setting "-clk". No KREL variable — KVER itself is the derived kernel release.
if [ "$(grep -rcF -- '--set-str LOCALVERSION "-clk"' scripts/01-build-kernel.sh)" = 1 ]; then ok "01 sets the clk lineage suffix (LOCALVERSION=-clk, exactly once)"; else no "01 missing/duplicated the clk LOCALVERSION lineage suffix"; fi
if grep -rF -- '--set-str LOCALVERSION' scripts/ | grep -vF '"-clk"' | grep -q .; then no "a non-lineage LOCALVERSION crept in (config properties must stay out of uname)"; else ok "no non-lineage LOCALVERSION in any script"; fi
if grep -rqw 'KREL' scripts/;                then no "KREL variable reintroduced (KVER is the derived kernel release)"; else ok "no KREL variable in any build script (incl. lib/)"; fi
# KVER becomes the DERIVED release post-olddefconfig (kernelrelease), and 05/upgrade-metal consume it
# through the stale-gated build.env like the rest of the pipeline.
if grep -qF 'make -s kernelrelease' scripts/01-build-kernel.sh; then ok "01 derives KVER from make kernelrelease"; else no "01 does not derive the kernel release"; fi
if grep -qF 'kernel_source=${KERNEL_SOURCE}' scripts/05-package-image.sh; then ok "05 stamps kernel_source + clk_commit provenance"; else no "05 provenance missing the kernel source"; fi
if grep -qF 'ciq-6.18.y' scripts/drift-check.sh && grep -qF 'row CLK' scripts/drift-check.sh; then ok "drift-check: CLK branch tip is the trigger row"; else no "drift-check missing the CLK trigger row"; fi
# Serve gate (#67): exists, fails closed on a dead container, and is a documented pre-sign release step.
if [ -f scripts/serve-gate.sh ] && grep -qF 'GATE-PASS' scripts/serve-gate.sh && grep -qF 'GATE-FAIL' scripts/serve-gate.sh; then ok "serve-gate.sh present + pass/fail-closed (#67)"; else no "serve-gate.sh missing or not fail-closed (#67)"; fi
if grep -qF 'serve-gate.sh' docs/build/build.md; then ok "release runbook requires the serve gate pre-sign (#67)"; else no "the release runbook (build.md) does not mandate the serve gate (#67)"; fi
# The MT7925 WiFi/BT firmware is RPM-PURE (#64): 02 dnf-installs the stock Rocky subpackages
# (mt7xxx-firmware + wireless-regdb) into the rootfs — no hand-decompressed files — and 01 enables
# FW_LOADER_COMPRESS_ZSTD so the kernel can load el10's compressed blobs regardless of .xz/.zst era.
if grep -qE 'dnf install .*mt7xxx-firmware wireless-regdb' scripts/02-build-rootfs.sh; then ok "02 installs the MT7925 firmware as stock RPMs (#64)"; else no "02 firmware install is not rpm-pure (#64)"; fi
if grep -qF 'zstd -d' scripts/02-build-rootfs.sh; then no "02 still hand-decompresses firmware — the rpm-pure fix removed this (#64)"; else ok "02 carries no hand-decompression of firmware (#64)"; fi
if grep -qF -- '--enable FW_LOADER_COMPRESS_ZSTD' scripts/01-build-kernel.sh; then ok "01 enables FW_LOADER_COMPRESS_ZSTD (#64 — the real root cause)"; else no "01 missing FW_LOADER_COMPRESS_ZSTD — .zst firmware cannot load (#64)"; fi
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
# The page-size pin maps to the config symbol IN 05's gate (audit #70 C6: test the real code, not a
# local re-implementation — the old pgsym self-test passed even if 05's mapping rotted).
if grep -qF 'WANT_PG=$([ "$PAGE_SIZE" = 64k ] && echo "CONFIG_ARM64_64K_PAGES=y" || echo "CONFIG_ARM64_4K_PAGES=y")' scripts/05-package-image.sh; then ok "05 derives the page-size gate symbol from the pin"; else no "05 page-size->symbol mapping missing/changed — the fail-closed gate may not match the pin"; fi
# --- the 64k correctness gate (#65 / NVIDIA open-gpu-kernel-modules#1269) ---
grep -q 'DRIVER_64K_SAFE=' config/versions.env && ok "versions.env declares DRIVER_64K_SAFE (the 64k gate input)" || no "versions.env: DRIVER_64K_SAFE missing — a 64k pin would ship ungated"
# --- WiFi usable end-to-end (#84). #64 shipped firmware only and validated link-up; four releases
# carried a radio NM reported 'unavailable'. These invariants make firmware-without-userspace unshippable. ---
grep -qE '^dnf install .*[[:space:]]NetworkManager-wifi[[:space:]]' scripts/04-build-image.sh && ok "04's dnf line installs NetworkManager-wifi (the NM device plugin)" || no "04: NetworkManager-wifi not on the dnf install line — base NetworkManager has NO wifi support (#84)"
grep -qE '^dnf install .*[[:space:]]wpa_supplicant[[:space:]]' scripts/04-build-image.sh && ok "04's dnf line installs wpa_supplicant (required to associate)" || no "04: wpa_supplicant not on the dnf install line — the radio cannot associate (#84)"
grep -qE '^rpm -q NetworkManager-wifi wpa_supplicant .*exit 1' scripts/04-build-image.sh && ok "04 fail-closed if the wifi userspace is absent" || no "04: no fail-closed rpm -q guard on the wifi userspace (#84)"
grep -qE "^find /usr/lib64/NetworkManager -name 'libnm-device-plugin-wifi.so'.*exit 1" scripts/04-build-image.sh && ok "04 fail-closed if the NM wifi plugin is absent" || no "04: no fail-closed check for the wifi device plugin (#84)"
grep -qF 'wifi.powersave=2' scripts/04-build-image.sh && ok "04 writes wifi.powersave=2 (off; PS on costs ~4.2x gateway RTT, measured 2026-08-03)" || no "04: wifi powersave not disabled by default (#84)"
grep -qE '^\s*cuda-nvcc.*gcc python3-devel' scripts/02-build-rootfs.sh && ok "02 installs gcc + python3-devel explicitly (torch-inductor JIT at vLLM engine init needs Python.h — hit live 2026-08-04)" || no "02: host JIT toolchain (gcc/python3-devel) not explicit — inductor-path CUDA workloads fail on a fresh image"
grep -qF 'rpm --root "$MNT" -q NetworkManager-wifi' scripts/05-package-image.sh && ok "05 gates the release on NetworkManager-wifi in the image" || no "05: release gate does not verify NetworkManager-wifi (#84)"
grep -qF 'rpm --root "$MNT" -q wpa_supplicant' scripts/05-package-image.sh && ok "05 gates the release on wpa_supplicant in the image" || no "05: release gate does not verify wpa_supplicant (#84)"
grep -qF 'name libnm-device-plugin-wifi.so' scripts/05-package-image.sh && ok "05 gates the release on the wifi device plugin" || no "05: release gate does not verify the wifi plugin (#84)"
grep -qF 'usr/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE' scripts/05-package-image.sh && ok "05 gates the release on mt7925 firmware (#64 and #84 checked together)" || no "05: release gate does not verify mt7925 firmware"
grep -qF '"$WSTATE" != unavailable' scripts/validate.sh && ok "doctor asserts the wifi device is NOT 'unavailable' (the state that actually shipped)" || no "validate.sh: no assertion against the 'unavailable' state (#84)"
grep -qF '"${APS:-0}" -ge 1' scripts/validate.sh && ok "doctor requires a SCAN to return APs — the real end-to-end wifi proof" || no "validate.sh: no scan-based wifi check; link-up alone is what #64 wrongly accepted"
grep -q 'PG64_OK' scripts/05-package-image.sh && ok "05 gates a 64k pin on DRIVER_64K_SAFE (fail-closed)" || no "05: 64k correctness gate missing"
case " $(. config/versions.env; echo "$DRIVER_64K_SAFE") " in *" $(. config/versions.env; echo "$DRIVER_VER")"*) no "DRIVER_64K_SAFE lists the shipping driver $(. config/versions.env; echo "$DRIVER_VER") — it carries the #1269 defect; a >=4 GiB allocation test must PASS before it earns that";; *) ok "DRIVER_64K_SAFE excludes the defect-carrying shipping driver";; esac
if [ "$(. config/versions.env; echo "$PAGE_SIZE")" = 64k ]; then case " $(. config/versions.env; echo "$DRIVER_64K_SAFE") " in *" $(. config/versions.env; echo "$DRIVER_VER") "*) ok "64k pin sits on a 64k-safe driver";; *) no "64k pin on a driver not in DRIVER_64K_SAFE — 05 will refuse (this is the gate working)";; esac; else ok "page-size pin is 4k (the #1269 trade; destination is 64k, see versions.env)"; fi
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
if grep -qF 'spark-rocky-metal-cmdline' scripts/upgrade-metal.sh; then ok "upgrade-metal preserves metal-only cmdline extras across kernel bumps (kdump, #62)"; else no "upgrade-metal drops metal-local cmdline extras on rewrite (#62)"; fi
if grep -qF 'Image-$KVER' scripts/upgrade-metal.sh && grep -q '41 52 4d 64' scripts/upgrade-metal.sh; then ok "upgrade-metal extracts + magic-verifies the raw Image for kdump on every kernel bump (#62)"; else no "upgrade-metal does not maintain the kdump raw Image (#62)"; fi
if grep -qF 'WIPE $TGT' scripts/install-baremetal.sh; then ok "install-baremetal requires a typed WIPE confirmation (#34)"; else no "install-baremetal has no typed-confirmation guard (#34)"; fi
if grep -qF 'install-baremetal.sh' scripts/04-build-image.sh; then no "the NVMe wiper is baked into the image — must stay a separate path (#34)"; else ok "the NVMe wiper is NOT baked into the image (#34)"; fi

# --- 05b boot gate (#86): the booted-artifact gate holds its hard-learned rules ---
if grep -q 'zero mounted filesystems' scripts/05b-boot-gate.sh && grep -qF 'lsblk -dno NAME,TRAN' scripts/05b-boot-gate.sh; then ok "05b resolves the flash target by identity (unmounted USB), never by letter (#86)"; else no "05b does not identity-resolve the flash target (#86)"; fi
if grep -qF 'boot-gate-return.service' scripts/05b-boot-gate.sh && grep -qF 'multi-user.target.wants' scripts/05b-boot-gate.sh; then ok "05b arms a self-return unit so a dark boot recovers the metal (#86)"; else no "05b has no dark-boot self-return (#86)"; fi
if grep -qF 'docker ps -q' scripts/05b-boot-gate.sh; then ok "05b refuses a busy box (shared-box arbitration, #86)"; else no "05b does not check for a busy box (#86)"; fi
if grep -qF 'findmnt -no SOURCE /' scripts/05b-boot-gate.sh && grep -q 'nvme' scripts/05b-boot-gate.sh; then ok "05b discriminates worlds by root device, not kernel string (#86)"; else no "05b does not discriminate boot worlds by root device (#86)"; fi
if grep -qF 'PARTUUID' scripts/05b-boot-gate.sh && grep -qF 'efibootmgr -n' scripts/05b-boot-gate.sh; then ok "05b resolves BootNext from the pinned ESP GUID (#47/#86)"; else no "05b does not resolve BootNext by ESP GUID (#86)"; fi
if grep -qF 'RESULT: PASS' scripts/05b-boot-gate.sh && grep -qF 'validate.sh' scripts/05b-boot-gate.sh; then ok "05b verdict comes from the doctor ON the booted artifact (#86)"; else no "05b does not gate on the booted doctor (#86)"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
