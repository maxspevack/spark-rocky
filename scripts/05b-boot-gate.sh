#!/bin/bash
# Boot the candidate image ON REAL HARDWARE before it can be signed (#85): flash it to the standing
# recovery stick, one-shot boot into it via UEFI BootNext, run the doctor ON THE BOOTED ARTIFACT over
# the image's own WiFi, then return to the metal. Catches the class no mounted-image gate can catch:
# releases 20260706-20260723 shipped a WiFi radio the OS could not drive with every gate green,
# because nothing ever booted the bytes we published (#84).
#
# Runs on the OPERATOR machine (it must survive the box rebooting under it), driving the box over SSH.
#
# Usage: BOOT_GATE_HOST=<ssh-host-reaching-the-box-as-root> scripts/05b-boot-gate.sh [image-path-on-box]
#   image-path-on-box   default: newest vend/*.raw.xz under BOX_REPO (default /root/spark-rocky)
#   BOOT_WAIT=480       seconds to wait for the booted image to answer over its own WiFi
#   SELF_RETURN_SECS=1200  dark-boot safety net baked onto the stick (must exceed boot+validate time)
#
# Rules encoded here, each one paid for on 2026-08-05 (the gate's first three runs):
#   - The flash target is resolved by IDENTITY — the single USB disk with zero mounted filesystems —
#     never by device letter: letters shuffle across reboots, and a stale "sda" nearly flashed the
#     mounted archive drive (write-usb's mounted-check refused it; this script never asks).
#   - Flash -> arm -> BootNext -> reboot is ONE gated chain: the reboot cannot fire on a partial arm.
#   - The armed stick carries a SELF-RETURN unit: if the image boots dark (the exact failure this
#     gate hunts), the box reboots itself back to the metal — headless, no LEDs, no physical trip.
#   - Worlds are told apart by root device (nvme = metal, sd*2 = stick), never by kernel string:
#     after an in-place metal upgrade both worlds report the same uname.
#   - The stick is a TEST VEHICLE: arming injects the WiFi profile + ssh key + return unit onto its
#     rootfs, so the booted rootfs differs from the vended artifact by exactly those files. The gate
#     validates the artifact's behavior; the artifact that gets signed is untouched.
set -uo pipefail

HOST="${BOOT_GATE_HOST:-}"
[ -n "$HOST" ] || { echo "usage: BOOT_GATE_HOST=<ssh-host> $0 [image-path-on-box]"; exit 2; }
BOX_REPO="${BOX_REPO:-/root/spark-rocky}"
IMG="${1:-}"
BOOT_WAIT="${BOOT_WAIT:-480}"
RETURN_WAIT="${RETURN_WAIT:-480}"
SELF_RETURN_SECS="${SELF_RETURN_SECS:-1200}"

# Host keys DIFFER between the metal and the booted image (images regenerate them), so this script
# cannot use the operator's known_hosts for either world.
SSHOPTS="-o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
S(){ ssh $SSHOPTS "$HOST" "$@"; }

step(){ echo "== $*"; }

# --- 0. Preflight: we are talking to the METAL, and the box is idle enough to reboot ---
step "preflight: metal + idle"
ROOTDEV=$(S 'findmnt -no SOURCE /' 2>/dev/null) || { echo "GATE-FAIL: box unreachable at $HOST"; exit 1; }
case "$ROOTDEV" in
  /dev/nvme*) ;;
  *) echo "GATE-FAIL: box is not on the metal (root=$ROOTDEV) — a previous gate may not have returned; refusing"; exit 1 ;;
esac
BUSY=$(S 'docker ps -q | wc -l')
[ "$BUSY" = "0" ] || { echo "GATE-FAIL: $BUSY container(s) running — a serve or benchmark owns the box; rerun when idle"; exit 1; }

# --- image path (newest vended candidate unless given) ---
[ -n "$IMG" ] || IMG=$(S "ls -t '$BOX_REPO'/vend/*.raw.xz 2>/dev/null | head -1")
[ -n "$IMG" ] || { echo "GATE-FAIL: no image under $BOX_REPO/vend and none given"; exit 1; }
S "[ -f '$IMG' ]" || { echo "GATE-FAIL: image not found on the box: $IMG"; exit 1; }
step "candidate: $IMG"

# --- 1. Resolve the flash target by identity: exactly ONE USB disk with zero mounted filesystems ---
step "resolving flash target (identity, never device letter)"
DEV=$(S '
  c=""
  for d in $(lsblk -dno NAME,TRAN | awk '"'"'$2=="usb"{print $1}'"'"'); do
    m=$(lsblk -no MOUNTPOINT "/dev/$d" | grep -c . || true)
    [ "$m" = "0" ] && c="$c /dev/$d"
  done
  set -- $c
  [ "$#" -eq 1 ] && printf "%s" "$1"
')
[ -n "$DEV" ] || { echo "GATE-FAIL: not exactly one unmounted USB disk on the box — plug/unplug until unambiguous (mounted drives are never targets)"; exit 1; }
step "target: $DEV ($(S "lsblk -dno MODEL,SIZE '$DEV'" | tr -s ' '))"

# --- 2. Flash + arm + BootNext + reboot: one gated chain on the box ---
step "flash + arm + BootNext (single gated chain)"
S "DEV='$DEV' IMG='$IMG' BOX_REPO='$BOX_REPO' SELF_RETURN_SECS='$SELF_RETURN_SECS' bash -s" <<'REMOTE' || { echo "GATE-FAIL: flash/arm chain did not complete — nothing was rebooted"; exit 1; }
set -euo pipefail
cd "$BOX_REPO"
WRITE_USB_ALLOW_NONREMOVABLE=1 ./scripts/write-usb.sh "$IMG" "$DEV" | tail -1
partprobe "$DEV"; sleep 2
MNT=$(mktemp -d)
mount "${DEV}2" "$MNT"
# arm: ssh key + every WiFi profile the metal has (the booted image joins the same network)
install -d -m 700 "$MNT/root/.ssh"
install -m 600 /root/.ssh/authorized_keys "$MNT/root/.ssh/authorized_keys"
install -d -m 755 "$MNT/etc/NetworkManager/system-connections"
found=0
for p in /etc/NetworkManager/system-connections/*.nmconnection; do
  [ -e "$p" ] && { install -m 600 "$p" "$MNT/etc/NetworkManager/system-connections/"; found=1; }
done
[ "$found" = 1 ] || { echo "ARM-FAIL: the metal has no NM WiFi profile to inject"; umount "$MNT"; exit 1; }
# self-return unit: a dark boot brings the metal back on its own
cat > "$MNT/etc/systemd/system/boot-gate-return.service" <<UNIT
[Unit]
Description=boot-gate self-return: reboot to the metal after ${SELF_RETURN_SECS}s (dark-boot safety net)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep ${SELF_RETURN_SECS}; systemctl reboot'
[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf ../boot-gate-return.service "$MNT/etc/systemd/system/multi-user.target.wants/boot-gate-return.service"
date -u +"armed=%Y-%m-%dT%H:%M:%SZ" > "$MNT/etc/boot-gate-armed"
umount "$MNT"; rmdir "$MNT"
echo "ARMED (wifi profile + ssh key + ${SELF_RETURN_SECS}s self-return)"
# BootNext resolved from the stick's ESP PARTUUID (#47 pins it inside the image)
GUID=$(lsblk -no PARTUUID "${DEV}1" | tr -d '[:space:]')
[ -n "$GUID" ]
NUM=$(efibootmgr | grep -i "$GUID" | head -1 | sed 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/')
[ -n "$NUM" ] || { echo "ARM-FAIL: no UEFI entry targets ESP $GUID — create once: efibootmgr -c -d $DEV -p 1 -L spark-rocky-gate -l '\\EFI\\BOOT\\BOOTAA64.EFI'"; exit 1; }
efibootmgr -n "$NUM" | grep BootNext
sync
(sleep 1; systemctl reboot) &
echo "REBOOTING into the candidate"
REMOTE

# --- 3. Wait for the booted image: root must be on the stick, not the NVMe ---
step "waiting for the booted image (up to ${BOOT_WAIT}s)"
went_down=0; WORLD=""
deadline=$(( SECONDS + BOOT_WAIT ))
while [ "$SECONDS" -lt "$deadline" ]; do
  R=$(S 'findmnt -no SOURCE /' 2>/dev/null) || { went_down=1; sleep 10; continue; }
  case "$R" in
    /dev/sd*2) WORLD=stick; break ;;
    /dev/nvme*)
      if [ "$went_down" = 1 ]; then echo "GATE-FAIL: box came back on the METAL — BootNext did not take (check the UEFI entry)"; exit 1; fi ;;
  esac
  sleep 10
done
if [ "$WORLD" != stick ]; then
  echo "GATE-FAIL: booted image never answered in ${BOOT_WAIT}s — boot or WiFi failure ON THE ARTIFACT (this is the class the gate exists to catch)."
  step "self-return unit will reboot the box to the metal ~${SELF_RETURN_SECS}s after its boot; waiting"
  deadline=$(( SECONDS + SELF_RETURN_SECS + RETURN_WAIT ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    R=$(S 'findmnt -no SOURCE /' 2>/dev/null) && case "$R" in /dev/nvme*) echo "metal is back"; exit 1;; esac
    sleep 20
  done
  echo "metal did not return on its own — power-cycle the box"; exit 1
fi
step "booted artifact answered (root=$(S 'findmnt -no SOURCE /'))"

# --- 4. The doctor runs ON the booted artifact, over the artifact's own radio ---
step "validate.sh on the booted image"
set +e
OUT=$(S '/root/validate.sh' 2>&1); VRC=$?
set -e 2>/dev/null || true
echo "$OUT" | tail -12
if echo "$OUT" | grep -q "RESULT: PASS"; then VERDICT=PASS; else VERDICT=FAIL; fi

# --- 5. Return to the metal (BootNext is spent; a plain reboot lands there) ---
step "returning to the metal"
S '(sleep 1; systemctl reboot) &' >/dev/null 2>&1 || true
deadline=$(( SECONDS + RETURN_WAIT ))
BACK=""
while [ "$SECONDS" -lt "$deadline" ]; do
  R=$(S 'findmnt -no SOURCE /' 2>/dev/null) && case "$R" in /dev/nvme*) BACK=1; break;; esac
  sleep 10
done
[ -n "$BACK" ] || { echo "WARN: metal not confirmed back within ${RETURN_WAIT}s — verify by hand"; }

if [ "$VERDICT" = PASS ] && [ "$VRC" = 0 ]; then
  echo "BOOT-GATE: PASS — the booted artifact validated over its own WiFi. Releasable (proceed to 06-sign)."
  exit 0
else
  echo "BOOT-GATE: FAIL — the booted artifact did not validate (rc=$VRC). NOT signable."
  exit 1
fi
