#!/bin/bash
# Build a bootable Rocky + $KVER disk IMAGE on the fast NVMe (fast small-file writes),
# then stream it to the USB stick in one sequential dd. Runs on the Spark as root.
# Parameterized via config/versions.env. The dd target is guarded: it MUST be a removable USB.
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
R="$W/rocky-img/rootfs"
IMG="$W/rocky-img/rocky-gb10.img"
DEV="${DEV:-/dev/sda}"
MNT=/mnt/rimg
[ -d "$R" ] || { echo "FATAL: rootfs missing — run 02/02b/02c first"; exit 1; }

# We build the IMAGE first — no USB required. Flashing to a physical USB is an OPTIONAL final step
# (guarded so it can only ever touch a removable USB, never the NVMe). The vend flow stops at the
# image: 05-package-image.sh consumes $IMG and colleagues write it to their own USB with an imager.

RSZ=$(du -sB1G "$R" | cut -f1); IMGSZ=$(( ${RSZ%G} + 2 ))   # +2G margin covers chroot pkg adds + initramfs + ext4 overhead
echo "rootfs ${RSZ} -> image ${IMGSZ}G"
rm -f "$IMG"; truncate -s ${IMGSZ}G "$IMG"
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart EFI fat32 1MiB 1025MiB
parted -s "$IMG" set 1 esp on
parted -s "$IMG" mkpart root ext4 1025MiB 100%
# Pin the ESP (partition 1) GUID to a FIXED value (#47). A USB-first firmware boot entry keys on
# HD(1,GPT,<part-guid>); parted assigns a RANDOM GUID per build, so re-flashing a newer image orphans the
# entry and the box falls through to the NVMe. A fixed GUID gives every spark-rocky USB one boot identity, so
# a single firmware entry stays valid across re-flashes (two USBs at once would collide -- two-USB is OOS).
command -v sgdisk >/dev/null 2>&1 || dnf install -y -q gdisk 2>/dev/null || true
sgdisk -u 1:A84952EE-452B-44B3-ACB5-B036BA8E6B0D "$IMG" >/dev/null
LOOP=$(losetup --find --show -P "$IMG"); sleep 1; echo "loop=$LOOP"
mkfs.fat -F32 -n ROCKYEFI ${LOOP}p1 >/dev/null
mkfs.ext4 -F -q -L rocky-root ${LOOP}p2
EFI_UUID=$(blkid -s UUID -o value ${LOOP}p1); ROOT_UUID=$(blkid -s UUID -o value ${LOOP}p2)
echo "EFI=$EFI_UUID ROOT=$ROOT_UUID"

mkdir -p "$MNT"; mount ${LOOP}p2 "$MNT"; mkdir -p "$MNT"/boot/efi; mount ${LOOP}p1 "$MNT"/boot/efi
echo "=== populate (fast, on NVMe) ==="; cp -a "$R"/. "$MNT"/
cat > "$MNT"/etc/fstab <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$EFI_UUID /boot/efi vfat umask=0077,shortname=winnt 0 2
EOF
sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$MNT"/etc/selinux/config 2>/dev/null||true
# DEBUG-ACCESS hatch (Bruce). NON-debug builds bake NO authorized_keys — that matches release posture
# (key-only sshd + no keys = no remote access; 05 strips too, belt-and-suspenders). NEVER copy the
# builder's personal key (it used to: cp /root/.ssh/authorized_keys — baked Max's key into every image).
# DEBUG=1 injects the DEDICATED debug pubkeys (config/debug-authorized_keys) + a marker that makes the
# image UN-RELEASABLE: 05's gate aborts the release if /etc/spark-rocky-debug-hatch is present.
if [ "${DEBUG:-0}" = 1 ]; then
  DBG="$HERE/../config/debug-authorized_keys"
  { [ -f "$DBG" ] && grep -q '^ssh-' "$DBG"; } || { echo "FATAL: DEBUG=1 but $DBG missing/empty"; exit 1; }
  mkdir -p "$MNT"/root/.ssh && grep '^ssh-' "$DBG" > "$MNT"/root/.ssh/authorized_keys
  chmod 700 "$MNT"/root/.ssh && chmod 600 "$MNT"/root/.ssh/authorized_keys
  date -u +%Y-%m-%dT%H:%M:%SZ > "$MNT/etc/spark-rocky-debug-hatch"
  echo "DEBUG-HATCH: injected $(grep -c '^ssh-' "$DBG") dedicated debug key(s) + marker — THIS IMAGE CANNOT BE RELEASED"
fi
# Validator easy-debug path (works on the locked RELEASE too): a one-command opt-in that authorizes the
# DEDICATED maintainer debug key. A stuck validator runs ONE line instead of typing an 80-char key; the
# release stays locked by default (no authorized_keys) until they choose to run it. Built from the same
# config/debug-authorized_keys (revoke by editing that file). Not a personal key.
DBG="$HERE/../config/debug-authorized_keys"
if [ -f "$DBG" ] && grep -q '^ssh-' "$DBG"; then
  { echo '#!/bin/bash'
    echo '# Run ONLY if the maintainer asks, to let them SSH in and debug this box. Dedicated key, not personal.'
    echo 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'
    echo 'cat >> /root/.ssh/authorized_keys <<KEYS'
    grep '^ssh-' "$DBG"
    echo 'KEYS'
    echo 'chmod 600 /root/.ssh/authorized_keys'
    echo 'echo "Debug access enabled. Tell the maintainer this box'\''s IP. Undo any time: rm /root/.ssh/authorized_keys"'
  } > "$MNT/root/spark-rocky-debug-enable.sh"
  chmod +x "$MNT/root/spark-rocky-debug-enable.sh"
fi
# The boot menuentry is generated ONCE and written to BOTH grub.cfg copies (root-partition + the EFI copy
# the prebuilt grubaa64.efi actually reads) so they cannot drift. Any cmdline change is made here, once.
GRUBCFG="set timeout=1
set default=0
insmod all_video
menuentry 'Rocky $ROCKY_RELEASEVER + $KVER (GB10)' {
  search --no-floppy --fs-uuid --set=root $ROOT_UUID
  linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID ro rootwait quiet loglevel=3 nvidia-drm.modeset=0 fbcon=nodefer iommu.passthrough=0 init_on_alloc=0 console=tty0 earlycon=uart,mmio32,0x16A00000 selinux=0
  initrd /boot/initramfs-$KVER.img
}"
mkdir -p "$MNT"/boot/grub2
printf '%s\n' "$GRUBCFG" > "$MNT"/boot/grub2/grub.cfg
for m in proc sys dev dev/pts; do mount --bind /$m "$MNT"/$m; done
mount -t tmpfs -o size=20G tmpfs "$MNT"/var/tmp   # dracut scratch in RAM, not the image root
# The chroot dnf below needs working DNS. A --installroot rootfs ships no usable /etc/resolv.conf, so without
# this the chroot cannot resolve the Rocky mirror and the dnf fails — THE root cause of #44: the old
# `|| true` masked that failure, zstd was never installed, and dracut silently fell back to gzip. NM
# regenerates resolv.conf on the target at first boot, so the copied file is transient. (install-baremetal
# does the same for its chroot.)
cp -fL /etc/resolv.conf "$MNT/etc/resolv.conf"
chroot "$MNT" /bin/bash <<CHROOT
set -e
dnf install -y -q grub2-efi-aa64 grub2-efi-aa64-modules shim-aa64 dracut-network NetworkManager openssh-server zstd
command -v zstd >/dev/null || { echo "FATAL: zstd missing in chroot -- dracut would silently fall back to gzip (#44)"; exit 1; }
echo 'root:rocky' | chpasswd   # DEV-IMAGE default — this box is LAN-only + reinstalled on demand; change before exposing off-LAN
systemctl enable sshd NetworkManager getty@tty1.service 2>/dev/null || true
# serial-getty@ttyS0 dropped + console=ttyS0 removed above: /dev/ttyS0 does not exist on the GB10, so
# it hung boot ~90s waiting for the device. earlycon still gives early-boot serial output; the vended
# image is monitor-driven.
# Only the management NIC (r8169) should DHCP — leave the cable-less ConnectX (mlx5) ports unmanaged so
# NetworkManager does not burn 45s per port on dead DHCP and flood the console.
mkdir -p /etc/NetworkManager/conf.d
printf '[keyfile]\nunmanaged-devices=driver:mlx5_core\n' > /etc/NetworkManager/conf.d/10-spark-unmanage.conf
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true   # do not block boot on the network
# The ConnectX/mlx5 NIC is the cluster-fabric port (cable-less here; single-host = multi-node out of scope).
# Don't load its driver — it floods dmesg hunting for firmware we deliberately don't ship in a minimal
# image (#30). Blacklist covers rootfs AND initramfs (dracut bundles /etc/modprobe.d). Re-enable if you
# ever cable the ConnectX for multi-node.
printf 'blacklist mlx5_core\ninstall mlx5_core /bin/true\n' > /etc/modprobe.d/blacklist-mlx5.conf
# First boot: the uninitialized machine-id (set in 05) flips ConditionFirstBoot, which otherwise runs
# systemd-firstboot and PROMPTS interactively for a timezone at the console. Set tz + locale and mask it.
ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
echo 'LANG=C.UTF-8' > /etc/locale.conf
systemctl mask systemd-firstboot.service 2>/dev/null || true
# Auto-login root at the console — validation image, nobody should type root/rocky; just run validate.sh.
mkdir -p /etc/systemd/system/getty@tty1.service.d
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear %%I\n' > /etc/systemd/system/getty@tty1.service.d/autologin.conf
# GB10 unified memory: swap-on-overcommit hangs the box ("zombie" instead of a clean CUDA OOM). Disable swap.
# (fstab here carries no swap; this mask is belt-and-suspenders so nothing activates swap at runtime.)
systemctl mask swap.target 2>/dev/null || true
mkdir -p /var/log/journal   # persistent journald — a thermal/OOM event must survive a power-off for forensics (volatile default lost the 2026-06-11 crash logs)
# --omit-drivers mlx5*: the unused ConnectX cluster NIC. In a --no-hostonly initramfs mlx5 is present and
# coldplug-loads at ~2s (before the rootfs blacklist applies), defeating the blacklist. Omitting it from the
# initramfs means it cannot load early; the rootfs blacklist then keeps it off post-switch-root (#30).
dracut --force --no-hostonly --compress zstd --omit-drivers "mlx5_core mlx5_ib mlx5_fwctl" --add-drivers "usb_storage uas xhci_pci xhci_hcd ehci_pci ext4 nvme" --kver $KVER /boot/initramfs-$KVER.img $KVER
CHROOT
# RHEL ships a PREBUILT grubaa64.efi (grub2-efi-aa64) — grub2-install --target=arm64-efi does NOT work here
# (no /usr/lib/grub/arm64-efi modules; it errors on modinfo.sh). The prebuilt binary reads its config from
# /EFI/rocky/grub.cfg (baked-in prefix, confirmed against the proven bare-metal box). So: write a
# self-contained menuentry there, and copy the prebuilt binary to the UEFI removable fallback
# /EFI/BOOT/BOOTAA64.EFI so the firmware boots the USB as removable media.
install -D -m644 "$MNT/boot/efi/EFI/rocky/grubaa64.efi" "$MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI" 2>/dev/null || true
printf '%s\n' "$GRUBCFG" > "$MNT/boot/efi/EFI/rocky/grub.cfg"
# Also place the config at the self-relative path, covering both possible prefixes of the prebuilt binary.
cp -f "$MNT/boot/efi/EFI/rocky/grub.cfg" "$MNT/boot/efi/EFI/BOOT/grub.cfg" 2>/dev/null || true
# Ship the GPU proof-of-life + the passive thermal/mem logger IN the image (run /root/proof-of-life.sh;
# run /root/templog.sh alongside a benchmark for a forensic trace — logging only, it throttles nothing).
[ -f "$HERE/proof-of-life.sh" ] && install -m755 "$HERE/proof-of-life.sh" "$MNT/root/proof-of-life.sh"
[ -f "$HERE/templog.sh" ] && install -m755 "$HERE/templog.sh" "$MNT/root/templog.sh"
[ -f "$HERE/check-throttle.sh" ] && install -m755 "$HERE/check-throttle.sh" "$MNT/root/check-throttle.sh"   # #43 post-hoc throttle gate (run-benchmark-matrix calls /root/check-throttle.sh)
# Verify the built image carries kernel + initramfs + grub BEFORE the flash (advisor: artifacts, not banners).
VERR=0
[ -f "$MNT/boot/vmlinuz-$KVER" ] || { echo "VERIFY-FAIL: no vmlinuz-$KVER in image"; VERR=1; }
ISZ=$(stat -c%s "$MNT/boot/initramfs-$KVER.img" 2>/dev/null || echo 0)
[ "$ISZ" -gt 5000000 ] || { echo "VERIFY-FAIL: initramfs-$KVER.img missing/tiny ($ISZ bytes)"; VERR=1; }
# Compression CONTENT, not just size: dracut exits 0 even when it silently falls back from zstd to gzip
# (#44). Assert the zstd frame magic (28 b5 2f fd) so a fallback fails the build instead of shipping.
[ "$(od -An -tx1 -N4 "$MNT/boot/initramfs-$KVER.img" 2>/dev/null | tr -d ' ')" = "28b52ffd" ] || { echo "VERIFY-FAIL: initramfs is not zstd-compressed — dracut fell back (#44)"; VERR=1; }
[ -f "$MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI" ] || { echo "VERIFY-FAIL: no /EFI/BOOT/BOOTAA64.EFI — USB would not boot as removable media"; VERR=1; }
[ -f "$MNT/boot/efi/EFI/rocky/grub.cfg" ] || { echo "VERIFY-FAIL: no /EFI/rocky/grub.cfg (the prebuilt grub's config path)"; VERR=1; }
grep -q "vmlinuz-$KVER" "$MNT/boot/efi/EFI/rocky/grub.cfg" 2>/dev/null || { echo "VERIFY-FAIL: /EFI/rocky/grub.cfg does not reference vmlinuz-$KVER"; VERR=1; }
# Boot-hygiene + the debug hatch: verified HERE too (not only in 05) so a DEV= direct-flash of this image is
# gated, not just the 05 release artifact. These are the properties that make the image boot clean + fast.
grep -q "nvidia-drm.modeset=0" "$MNT/boot/grub2/grub.cfg" 2>/dev/null || { echo "VERIFY-FAIL: nvidia-drm.modeset=0 missing from grub.cfg"; VERR=1; }
grep -q -- "--autologin root" "$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf" 2>/dev/null || { echo "VERIFY-FAIL: console autologin drop-in missing"; VERR=1; }
grep -q "blacklist mlx5_core" "$MNT/etc/modprobe.d/blacklist-mlx5.conf" 2>/dev/null || { echo "VERIFY-FAIL: mlx5_core not blacklisted (#30)"; VERR=1; }
[ "$(readlink "$MNT/etc/systemd/system/swap.target" 2>/dev/null)" = /dev/null ] || { echo "VERIFY-FAIL: swap.target not masked"; VERR=1; }
[ "$(readlink "$MNT/etc/systemd/system/systemd-firstboot.service" 2>/dev/null)" = /dev/null ] || { echo "VERIFY-FAIL: systemd-firstboot not masked"; VERR=1; }
[ -x "$MNT/root/spark-rocky-debug-enable.sh" ] || { echo "VERIFY-FAIL: spark-rocky-debug-enable.sh not baked (debug hatch missing — the \$HERE/../config path bug)"; VERR=1; }
[ "$VERR" = 0 ] && echo "IMAGE-VERIFY-OK: vmlinuz-$KVER + zstd initramfs ($ISZ bytes) + BOOTAA64.EFI + grub + boot-hygiene + debug-hatch present"
for m in var/tmp dev/pts dev sys proc; do umount -l "$MNT"/$m 2>/dev/null||true; done
umount "$MNT"/boot/efi 2>/dev/null||true; umount "$MNT" 2>/dev/null||true; losetup -d "$LOOP"; sync
[ "$VERR" = 0 ] || { echo "ABORT: image failed verification"; exit 1; }
echo "IMAGE-VERIFY-OK -> $IMG ($(stat -c%s "$IMG" 2>/dev/null) bytes)"
# OPTIONAL flash: only if $DEV is a present, removable USB. Absent or non-USB -> skip cleanly (the
# image is the deliverable; 05 packages it; colleagues write it themselves). The guard makes
# flashing the NVMe impossible regardless of what $DEV is set to.
if [ "$(lsblk -dno TRAN "$DEV" 2>/dev/null|tr -d '[:space:]')" = usb ] && [ "$(lsblk -dno RM "$DEV" 2>/dev/null|tr -d '[:space:]')" = 1 ]; then
  echo "=== flashing $IMG -> $DEV ($(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null)) ==="
  for p in "$DEV"?*; do umount "$p" 2>/dev/null||true; done
  dd if="$IMG" of="$DEV" bs=16M oflag=direct status=progress; sync
  # backup GPT header lands mid-disk on a larger stick; relocate it so a clean reproducer shows no GPT errors.
  command -v sgdisk >/dev/null 2>&1 || dnf install -y -q gdisk 2>/dev/null || true
  command -v sgdisk >/dev/null 2>&1 && sgdisk -e "$DEV" >/dev/null 2>&1 && echo "GPT backup header relocated"
  partprobe "$DEV" 2>/dev/null || true; sync
  echo "USB-IMAGE-DONE $KVER -> $DEV"
else
  echo "no removable USB at $DEV — skipping flash. Image ready at $IMG; package it with scripts/05-package-image.sh."
fi
