#!/bin/bash
# Deliberate, NON-destructive in-place kernel upgrade of the running Spark NVMe metal (#34).
#
# Installs the freshly-built $KVER kernel + modules + open .ko + a fresh zstd initramfs ALONGSIDE the running
# kernel and makes it the GRUB default, KEEPING the currently-running kernel as a labeled fallback. No wipe;
# the running install's data / docker / authorized_keys are untouched. Run as root ON the metal (which is also
# the build host), AFTER a successful 01->04 build.
#
# vs install-baremetal.sh: that is a from-scratch WIPE + rsync (a clean reinstall onto a bare disk, run from a
# booted USB). THIS is an additive kernel upgrade of an existing, working install — prefer it for staying
# current. Neither is baked into the released image (#34): both are deliberate, repo-run, documented paths.
#
# Validated end-to-end on the GB10 (2026-06-29): the 6.18.35-64k metal upgraded in place to 6.18.37, booted,
# proof-of-life CUDA PASS, with 6.18.35-64k retained as the GRUB fallback.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER (+ the rest)
W="${W:-$(dirname "$HERE")}"
ROOT_UUID=$(findmnt -no UUID /)
ROOT_DEV=$(findmnt -no SOURCE /)
PREV=$(uname -r)
GRUBCFG=/boot/efi/EFI/rocky/grub.cfg
# Image boot-hygiene cmdline — mirrors 04-build-image.sh's GRUBCFG (a guarded coupling; the test suite checks
# the two carry the same hygiene flags). Any cmdline change is made in 04 first, then here.
CMDLINE="ro rootwait quiet loglevel=3 nvidia-drm.modeset=0 fbcon=nodefer iommu.passthrough=0 init_on_alloc=0 console=tty0 earlycon=uart,mmio32,0x16A00000 selinux=0"

echo "== in-place upgrade: $PREV -> $KVER (root=$ROOT_DEV UUID=$ROOT_UUID) =="
[ "$(id -u)" = 0 ]        || { echo "FATAL: run as root"; exit 1; }
[ "$KVER" != "$PREV" ]    || { echo "FATAL: build KVER ($KVER) == running kernel ($PREV) — nothing to upgrade"; exit 1; }
[ -f "$W/linux-$KVER/arch/arm64/boot/Image" ]      || { echo "FATAL: kernel Image missing in $W/linux-$KVER — run 01-04 first"; exit 1; }
[ -d "$W/rocky-img/rootfs/lib/modules/$KVER" ]     || { echo "FATAL: modules tree missing — run 02/02b first"; exit 1; }
VM=$(modinfo -F vermagic "$W/rocky-img/rootfs/lib/modules/$KVER/extra/nvidia.ko" 2>/dev/null | awk '{print $1}')
[ "$VM" = "$KVER" ]       || { echo "FATAL: open .ko vermagic '$VM' != $KVER"; exit 1; }
command -v zstd >/dev/null || { echo "FATAL: zstd missing (initramfs would silently fall back to gzip)"; exit 1; }
[ -f "$GRUBCFG" ]         || { echo "FATAL: $GRUBCFG not found — is this the spark-rocky metal?"; exit 1; }

echo "== install kernel + modules =="
cp -f "$W/linux-$KVER/arch/arm64/boot/Image" "/boot/vmlinuz-$KVER"
rm -rf "/lib/modules/$KVER"; cp -a "$W/rocky-img/rootfs/lib/modules/$KVER" "/lib/modules/$KVER"; depmod "$KVER"
grep -q "extra/nvidia.ko" "/lib/modules/$KVER/modules.dep" || { echo "FATAL: nvidia.ko not in modules.dep after depmod"; exit 1; }

echo "== build initramfs (04's flags) =="
dracut --force --no-hostonly --compress zstd --omit-drivers "mlx5_core mlx5_ib mlx5_fwctl" \
  --add-drivers "usb_storage uas xhci_pci xhci_hcd ehci_pci ext4 nvme" --kver "$KVER" "/boot/initramfs-$KVER.img" "$KVER"
ISZ=$(stat -c%s "/boot/initramfs-$KVER.img" 2>/dev/null || echo 0)
{ [ "$ISZ" -gt 5000000 ] && [ "$(od -An -tx1 -N4 "/boot/initramfs-$KVER.img" | tr -d ' ')" = 28b52ffd ]; } \
  || { echo "FATAL: initramfs-$KVER missing/too-small/not-zstd ($ISZ bytes)"; exit 1; }

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

echo ""
echo "UPGRADE-METAL-OK: $KVER installed as default; $PREV kept as the GRUB fallback (one menu entry away)."
echo "Reboot to boot $KVER; if anything is off, pick the '$PREV [previous - fallback]' entry at the 5s menu."
