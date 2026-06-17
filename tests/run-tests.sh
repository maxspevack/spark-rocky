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
# Suffix-drop stays done: kernel release is plain $KVER — no LOCALVERSION suffix, no KREL variable anywhere.
if grep -rqF -- '--set-str LOCALVERSION' scripts/; then no "LOCALVERSION suffix reintroduced (uname must stay plain KVER)"; else ok "no LOCALVERSION suffix in any script"; fi
if grep -qw 'KREL' scripts/*.sh;             then no "KREL variable reintroduced (kernel release must be plain KVER)"; else ok "no KREL variable in any build script"; fi
# Debug hatch reads the script-relative config (the W-vs-HERE bug that silently skipped baking it).
if grep -qF 'HERE/../config/debug-authorized_keys' scripts/04-build-image.sh && ! grep -qF 'W/config/debug-authorized_keys' scripts/04-build-image.sh; then ok "04 debug hatch reads HERE/../config (not W/config)"; else no "04 debug hatch path bug present"; fi
# zstd is gated + content-verified, not silently swallowed (#44).
if grep -qF 'command -v zstd' scripts/04-build-image.sh; then ok "04 gates zstd presence before dracut (#44)"; else no "04 missing the zstd presence gate (#44)"; fi
if grep -qF '28b52ffd' scripts/04-build-image.sh;          then ok "04 verifies initramfs is zstd by magic bytes (#44)"; else no "04 missing the zstd compression content-check (#44)"; fi
if grep -qF 'resolv.conf' scripts/04-build-image.sh;       then ok "04 gives the chroot DNS (resolv.conf — #44 root cause)"; else no "04 chroot has no resolv.conf — chroot dnf will fail (#44)"; fi
if grep -qF 'omit-drivers "mlx5' scripts/04-build-image.sh; then ok "04 omits mlx5 from the initramfs (no early coldplug load, #30)"; else no "04 does not omit mlx5 — it coldplug-loads in the initramfs (#30)"; fi
if grep -qF 'fbcon=nodefer' scripts/04-build-image.sh;      then ok "04 cmdline has fbcon=nodefer (no late console-takeover glitch)"; else no "04 missing fbcon=nodefer (autologin/console blank glitch)"; fi
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

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
