#!/bin/bash
# Write the vended spark-rocky image to a USB stick — WITH A 5-MINUTE WRITE-TIME GATE.
# The whole point of this image is "boot it in a few minutes." If the write does not finish within
# 5 minutes it FAILS: the stick or port is too slow for that promise — use a faster USB 3.x stick
# on a USB 3.x / USB-C port. Decompresses .xz on the fly. Same removable-USB guard as the build:
# it will refuse to touch anything that is not a removable USB, so it can never hit an internal disk.
#
# Usage: sudo ./write-usb.sh <image.raw.xz> </dev/sdX>
# (GUI alternative — Raspberry Pi Imager / balenaEtcher — reads .xz directly but cannot enforce the
#  gate; expect ~2-4 min, and if it is dragging well past that, your stick/port is the problem.)
set -uo pipefail
BUDGET="${BUDGET:-300}"                 # seconds; 5 minutes
IMG="${1:-}"; DEV="${2:-}"
[ -f "$IMG" ] && [ -n "$DEV" ] || { echo "usage: sudo $0 <image.raw.xz> </dev/sdX>"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "FATAL: must run as root (writes a block device)"; exit 2; }
command -v xz >/dev/null 2>&1 || { echo "FATAL: xz not installed"; exit 2; }
# Guard: only ever write a removable USB. /dev/nvme0n1 is TRAN=nvme RM=0 and fails this check.
[ "$(lsblk -dno TRAN "$DEV" 2>/dev/null|tr -d '[:space:]')" = usb ] \
  && [ "$(lsblk -dno RM "$DEV" 2>/dev/null|tr -d '[:space:]')" = 1 ] \
  || { echo "REFUSE: $DEV is not a removable USB (TRAN=$(lsblk -dno TRAN "$DEV" 2>/dev/null) RM=$(lsblk -dno RM "$DEV" 2>/dev/null))"; exit 2; }

echo "writing $(basename "$IMG") -> $DEV ($(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null)); budget ${BUDGET}s"
for p in "$DEV"?*; do umount "$p" 2>/dev/null || true; done
START=$SECONDS
if timeout "$BUDGET" bash -c 'xz -dc "$1" | dd of="$2" bs=16M oflag=direct status=progress' _ "$IMG" "$DEV"; then
  sync; ELAPSED=$((SECONDS-START))
  echo "WRITE-OK in ${ELAPSED}s (budget ${BUDGET}s) -> $DEV"
  echo "Now boot the Spark off this USB and run /root/validate.sh"
else
  RC=$?
  sync
  if [ "$RC" = 124 ]; then
    echo "WRITE-FAIL: exceeded the ${BUDGET}s (5-minute) budget. The stick or port is too slow"
    echo "            for this image. Use a USB 3.x stick on a USB 3.x / USB-C port and retry."
  else
    echo "WRITE-FAIL (rc=$RC) — see the dd output above."
  fi
  exit 1
fi
