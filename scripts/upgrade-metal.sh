#!/bin/bash
# Deliberate, NON-destructive in-place upgrade of the running Spark NVMe metal (#34): kernel, driver, or both.
#
# Converges the metal on the freshly-built tree — whatever config/versions.env pins and 01->04 built. The case
# is dispatched from what actually differs (no flags to get wrong):
#   KERNEL bump (KVER != running)      install the $KVER kernel + modules + fresh zstd initramfs ALONGSIDE the
#                                      running kernel; GRUB default flips, the running kernel stays as a labeled
#                                      fallback. No wipe; the install's data / docker / authorized_keys untouched.
#   DRIVER-only bump (KVER == running, swap the open .ko set in /lib/modules/$KVER/extra + depmod, install the
#     DRIVER_VER != installed)         matched .run userspace (sha256-gated against DRIVER_SHA256), rebuild the
#                                      initramfs (it carries nvidia). GRUB untouched — same kernel. The replaced
#                                      .ko set is staged under /root/driver-rollback-<old-ver>/ first.
#   both current                       refuse — nothing to upgrade.
# A KERNEL bump also syncs the driver userspace when it differs (the copied modules tree already carries the
# new .ko; userspace must move with it — NVIDIA kernel module and userspace are a matched pair).
#
# vs install-baremetal.sh: that is a from-scratch WIPE + rsync (a clean reinstall onto a bare disk, run from a
# booted USB). THIS is an additive upgrade of an existing, working install — prefer it for staying current.
# Neither is baked into the released image (#34): both are deliberate, repo-run, documented paths.
#
# Kernel path validated end-to-end on the GB10 (2026-06-29): 6.18.35-64k -> 6.18.37 in place, booted,
# proof-of-life CUDA PASS, fallback retained. Driver-only path encodes the sequence hardware-validated
# 2026-07-16 (610.43.02 -> 610.43.03 on 6.18.38: .ko swap + depmod + userspace + initramfs rebuild, rebooted,
# driver+GSP 610.43.03, CUDA vectorAdd PASS, dmesg baseline-diff clean — zero new err/crit lines).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, DRIVER_SHA256 (+ the rest)
W="${W:-$(dirname "$HERE")}"
# build.env: 01's resolved-KVER handoff (clk derives the release, e.g. 6.18.38-clk). Fail closed on
# staleness — never install a kernel whose source/pin diverged from the current versions.env.
source "$HERE/lib/build-env-gate.sh"   # fail-closed staleness gate on 01's build.env (one impl — audit #70 C1)
ROOT_UUID=$(findmnt -no UUID /)
ROOT_DEV=$(findmnt -no SOURCE /)
PREV=$(uname -r)
GRUBCFG=/boot/efi/EFI/rocky/grub.cfg
# Image boot-hygiene cmdline — mirrors 04-build-image.sh's GRUBCFG (a guarded coupling; the test suite checks
# the two carry the same hygiene flags). Any cmdline change is made in 04 first, then here.
CMDLINE="ro rootwait quiet loglevel=3 nvidia-drm.modeset=0 fbcon=nodefer iommu.passthrough=0 init_on_alloc=0 console=tty0 earlycon=uart,mmio32,0x16A00000 selinux=0"

# ---- dispatch: what actually differs? ----
# Installed driver userspace = the libcuda.so.1 symlink target (on-disk truth; needs no loaded GPU driver).
DRV_INSTALLED=$(basename "$(readlink -f /usr/lib64/libcuda.so.1 2>/dev/null)" 2>/dev/null | sed 's/^libcuda\.so\.//')
KCH=0; [ "$KVER" != "$PREV" ] && KCH=1
DCH=0; [ "$DRIVER_VER" != "$DRV_INSTALLED" ] && DCH=1

echo "== in-place upgrade: kernel $PREV -> $KVER, driver ${DRV_INSTALLED:-none} -> $DRIVER_VER (root=$ROOT_DEV UUID=$ROOT_UUID) =="
[ "$(id -u)" = 0 ]        || { echo "FATAL: run as root"; exit 1; }
[ "$KCH$DCH" != 00 ]      || { echo "FATAL: kernel ($KVER) and driver ($DRIVER_VER) both match the running metal — nothing to upgrade"; exit 1; }
[ -d "$W/rocky-img/rootfs/lib/modules/$KVER" ]     || { echo "FATAL: modules tree missing — run 02/02b first"; exit 1; }
KO_SRC="$W/rocky-img/rootfs/lib/modules/$KVER/extra/nvidia.ko"
VM=$(modinfo -F vermagic "$KO_SRC" 2>/dev/null | awk '{print $1}')
[ "$VM" = "$KVER" ]       || { echo "FATAL: open .ko vermagic '$VM' != $KVER"; exit 1; }
BUILT_DRV=$(modinfo -F version "$KO_SRC" 2>/dev/null)
[ "$BUILT_DRV" = "$DRIVER_VER" ] || { echo "FATAL: built .ko is driver '$BUILT_DRV' but versions.env pins $DRIVER_VER — stale build tree; rerun 01-04"; exit 1; }
command -v zstd >/dev/null || { echo "FATAL: zstd missing (initramfs would silently fall back to gzip)"; exit 1; }
[ -f "$GRUBCFG" ]         || { echo "FATAL: $GRUBCFG not found — is this the spark-rocky metal?"; exit 1; }

# The open .ko set installs as the kmod rpm on BOTH dispatch paths (#77): same-name new-version =
# a clean dnf upgrade on a driver bump; same-NEVRA re-run = reinstall (idempotent). /lib/modules on
# the metal is 100% rpm-owned (kernel rpm + this).
install_kmod_rpm() {
  [ -n "${KMODRPM:-}" ] || { echo "FATAL: KMODRPM not set — build.env predates the kmod-rpm pipeline; rerun 02b"; exit 1; }
  [ -f "$W/$KMODRPM" ]  || { echo "FATAL: kmod rpm $W/$KMODRPM missing — rerun 02b"; exit 1; }
  local NEVRA; NEVRA=$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$W/$KMODRPM")
  local OP=install; rpm -q "$NEVRA" >/dev/null 2>&1 && OP=reinstall
  dnf -y -q --nogpgcheck --setopt=tsflags=noscripts "$OP" "$W/$KMODRPM" \
    || { echo "FATAL: dnf $OP of $KMODRPM failed"; exit 1; }
}

if [ "$KCH" = 1 ]; then
  echo "== install kernel from the rpm (#59): ${KRPM:-UNSET} =="
  # dnf-install (not file copies): the metal's rpm database stays truthful — rpm -q kernel names what
  # actually boots. tsflags=noscripts: the rpm %post runs kernel-install/BLS; this box owns its own boot
  # plumbing (static GRUB + our dracut below), so we replicate the %post file copies ourselves.
  [ -n "${KRPM:-}" ] || { echo "FATAL: KRPM not set — build.env predates the rpm pipeline; rerun 01-build-kernel.sh"; exit 1; }
  [ -f "$W/$KRPM" ]  || { echo "FATAL: kernel rpm $W/$KRPM missing — rerun 01-build-kernel.sh"; exit 1; }
  NEVRA=$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$W/$KRPM")
  if rpm -q "$NEVRA" >/dev/null 2>&1; then DNFOP=reinstall; else DNFOP=install; fi   # idempotent re-run
  dnf -y -q --nogpgcheck --setopt=tsflags=noscripts "$DNFOP" "$W/$KRPM" \
    || { echo "FATAL: dnf $DNFOP of $KRPM failed"; exit 1; }
  # The skipped %post copies vmlinuz/System.map/config from /lib/modules/$KVER/ to /boot; do it ourselves.
  for f in vmlinuz System.map config; do
    cp -f "/lib/modules/$KVER/$f" "/boot/$f-$KVER" || { echo "FATAL: $f missing from the kernel rpm"; exit 1; }
  done
  # The kernel rpm carries only the kernel's own modules — the open NVIDIA .ko set arrives as the kmod
  # rpm (#77, built by 02b). Without it a kernel bump silently sheds the GPU driver (the modules.dep
  # gate below backstops).
  install_kmod_rpm
  depmod "$KVER"
else
  echo "== driver-only: swap the open .ko set via the kmod rpm (kernel $KVER unchanged) =="
  BK="/root/driver-rollback-${DRV_INSTALLED:-unknown}"
  mkdir -p "$BK"; cp -a "/lib/modules/$KVER/extra/"*.ko "$BK"/ 2>/dev/null || true
  install_kmod_rpm
  depmod "$KVER"
  echo "   replaced .ko set staged at $BK (kernel-side rollback; userspace rollback needs the $DRV_INSTALLED .run)"
fi
grep -q "extra/nvidia.ko" "/lib/modules/$KVER/modules.dep" || { echo "FATAL: nvidia.ko not in modules.dep after depmod"; exit 1; }

# Provenance stamp: the upgraded metal is SELF-DESCRIBING — the doctor (validate.sh) reads this to
# confirm the box runs what was built. 05 stamps images; this is the metal's equivalent (found missing
# by the doctor after the 2026-07-23 .39 upgrade — audit #70).
cat > /etc/spark-rocky-release <<EOF
spark-rocky metal (in-place upgrade)
build_id=metal-upgrade-$(date -u +%Y%m%d)
kernel=$KVER
kernel_rpm=$(rpm -qf "/lib/modules/$KVER/vmlinuz" 2>/dev/null || echo not-rpm-managed)
kernel_source=$KERNEL_SOURCE
clk_commit=${CLK_COMMIT:-}
page_size=$PAGE_SIZE
driver=$DRIVER_VER
upgraded_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

if [ "$DCH" = 1 ]; then
  echo "== driver userspace ${DRV_INSTALLED:-none} -> $DRIVER_VER (.run, sha256-gated) =="
  RUN="$W/driver-610/NVIDIA-Linux-aarch64-$DRIVER_VER.run"
  [ -f "$RUN" ] || { echo "FATAL: $RUN missing — run 02b first (it downloads the .run)"; exit 1; }
  echo "$DRIVER_SHA256  $RUN" | sha256sum -c - >/dev/null 2>&1 \
    || { echo "FATAL: .run sha256 != pinned DRIVER_SHA256 (versions.env) — refusing to install"; exit 1; }
  sh "$RUN" --no-kernel-modules --no-questions --ui=none --no-x-check --no-nouveau-check --install-libglvnd 2>&1 | tail -2
  [ -d "/lib/firmware/nvidia/$DRIVER_VER" ]  || { echo "FATAL: no /lib/firmware/nvidia/$DRIVER_VER after the userspace install (GSP firmware missing)"; exit 1; }
  [ -e "/usr/lib64/libcuda.so.$DRIVER_VER" ] || { echo "FATAL: libcuda.so.$DRIVER_VER not installed"; exit 1; }
fi

echo "== build initramfs (04's flags) =="
dracut --force --no-hostonly --compress zstd --omit-drivers "mlx5_core mlx5_ib mlx5_fwctl" \
  --add-drivers "usb_storage uas xhci_pci xhci_hcd ehci_pci ext4 nvme" --kver "$KVER" "/boot/initramfs-$KVER.img" "$KVER"
ISZ=$(stat -c%s "/boot/initramfs-$KVER.img" 2>/dev/null || echo 0)
{ [ "$ISZ" -gt 5000000 ] && [ "$(od -An -tx1 -N4 "/boot/initramfs-$KVER.img" | tr -d ' ')" = 28b52ffd ]; } \
  || { echo "FATAL: initramfs-$KVER missing/too-small/not-zstd ($ISZ bytes)"; exit 1; }

if [ "$KCH" = 1 ]; then
  echo "== rewrite GRUB (backup first; $KVER default, $PREV fallback) =="
  cp -f "$GRUBCFG" "$GRUBCFG.bak-pre-$KVER"
  cat > "$GRUBCFG" <<EOF
load_env
set default=0
set timeout=5
if [ "\${next_entry}" ] ; then set default="\${next_entry}"; set next_entry=; save_env next_entry; fi
insmod all_video
menuentry 'Rocky + $KVER (GB10) [default]' {
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID $CMDLINE
  initrd /boot/initramfs-$KVER.img
}
menuentry 'Rocky + $PREV (GB10) [previous - fallback]' {
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  linux /boot/vmlinuz-$PREV root=UUID=$ROOT_UUID $CMDLINE
  initrd /boot/initramfs-$PREV.img
}
EOF
  { grep -q "vmlinuz-$KVER" "$GRUBCFG" && grep -q "vmlinuz-$PREV" "$GRUBCFG"; } \
    || { echo "FATAL: new grub.cfg missing an entry — restoring backup"; cp -f "$GRUBCFG.bak-pre-$KVER" "$GRUBCFG"; exit 1; }
fi

echo ""
if [ "$KCH" = 1 ]; then
  echo "UPGRADE-METAL-OK: kernel $KVER installed as default; $PREV kept as the GRUB fallback (one menu entry away)."
  [ "$DCH" = 1 ] && echo "  driver userspace synced to $DRIVER_VER. NOTE: the $PREV fallback keeps its old .ko while userspace moved — on a fallback boot the GPU may refuse to init (version mismatch); SSH and the OS still come up."
  echo "Reboot to boot $KVER; if anything is off, pick the '$PREV [previous - fallback]' entry at the 5s menu."
else
  echo "UPGRADE-METAL-OK: driver ${DRV_INSTALLED:-none} -> $DRIVER_VER on kernel $KVER (GRUB untouched)."
  echo "Reboot to load the new driver. Rollback: restore $BK/*.ko + depmod, reinstall the $DRV_INSTALLED .run userspace, rebuild the initramfs, reboot."
fi
