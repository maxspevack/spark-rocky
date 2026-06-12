#!/bin/bash
# Write the vended image to a USB and CHECK THE WRITE THROUGHPUT — the metric that actually predicts
# the experience — instead of a wall-clock stopwatch. A fixed time limit conflates two unrelated
# things (stick speed and image size), so it would fail a perfectly good stick the day the image
# grows. Throughput (MB/s) is size-independent: it measures the stick+port, which is what determines
# whether this boots in a few minutes.
#
# Gate: measured write throughput must clear MIN_MBPS (default 40). Rationale, not a magic number:
# USB 2.0 tops out ~30-35 MB/s practical, USB 3.x is 100+; 40 requires real USB 3.x and writes our
# ~6 GB image in ~2.5 min. Override with MIN_MBPS=. The rate is reported either way. A hang-guard
# (HANG_GUARD, default 30 min) stops a truly stuck write — it is a backstop, NOT the gate.
#
# Usage: sudo ./write-usb.sh <image.raw.xz> </dev/sdX>
# (GUI alternative — Raspberry Pi Imager / balenaEtcher — reads .xz directly but can't report the
#  rate; the imager shows its own MB/s, eyeball it against ~40.)
set -uo pipefail
MIN_MBPS="${MIN_MBPS:-40}"
HANG_GUARD="${HANG_GUARD:-1800}"
IMG="${1:-}"; DEV="${2:-}"
[ -f "$IMG" ] && [ -n "$DEV" ] || { echo "usage: sudo $0 <image.raw.xz> </dev/sdX>"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "FATAL: must run as root (writes a block device)"; exit 2; }
command -v xz >/dev/null 2>&1 || { echo "FATAL: xz not installed"; exit 2; }
# Guard: only ever write a removable USB. /dev/nvme0n1 is TRAN=nvme RM=0 and fails this check.
[ "$(lsblk -dno TRAN "$DEV" 2>/dev/null|tr -d '[:space:]')" = usb ] \
  && [ "$(lsblk -dno RM "$DEV" 2>/dev/null|tr -d '[:space:]')" = 1 ] \
  || { echo "REFUSE: $DEV is not a removable USB (TRAN=$(lsblk -dno TRAN "$DEV" 2>/dev/null) RM=$(lsblk -dno RM "$DEV" 2>/dev/null))"; exit 2; }

# Uncompressed size (what actually lands on the stick) for the throughput math.
USZ=$(xz --robot --list "$IMG" 2>/dev/null | awk -F'\t' '$1=="file"{print $5; exit}')
[[ "$USZ" =~ ^[0-9]+$ ]] || USZ=0
echo "writing $(basename "$IMG") -> $DEV ($(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null)); floor ${MIN_MBPS} MB/s"
for p in "$DEV"?*; do umount "$p" 2>/dev/null || true; done

START=$SECONDS
# iflag=fullblock is REQUIRED on a pipe: without it dd writes whatever short chunk xz hands it
# (often 64 KB) as a separate direct write, which collapses throughput and makes the MB/s metric
# measure dd's inefficiency, not the stick. fullblock accumulates a real 16 MB block per write.
timeout "$HANG_GUARD" bash -c 'xz -dc "$1" | dd of="$2" bs=16M iflag=fullblock oflag=direct status=progress' _ "$IMG" "$DEV"
RC=$?; sync; ELAPSED=$(( SECONDS - START )); [ "$ELAPSED" -lt 1 ] && ELAPSED=1

[ "$RC" = 124 ] && { echo "WRITE-FAIL: hit the ${HANG_GUARD}s hang-guard — the write stalled."; exit 1; }
[ "$RC" = 0 ]   || { echo "WRITE-FAIL (rc=$RC) — see the dd output above."; exit 1; }

if [ "$USZ" -gt 0 ]; then
  MBPS=$(( USZ / 1048576 / ELAPSED ))
  echo "metric: wrote $(( USZ / 1048576 )) MiB in ${ELAPSED}s = ${MBPS} MB/s (floor ${MIN_MBPS} MB/s)"
  if [ "$MBPS" -lt "$MIN_MBPS" ]; then
    echo "WRITE-FAIL: ${MBPS} MB/s is below the ${MIN_MBPS} MB/s floor — this stick/port is USB-2.0-class."
    echo "            Use a USB 3.x stick on a USB 3.x / USB-C port; boot-in-a-few-minutes needs it."
    exit 1
  fi
  echo "WRITE-OK: ${MBPS} MB/s. Boot the Spark off this USB and run /root/validate.sh"
else
  echo "WRITE-OK in ${ELAPSED}s (couldn't read uncompressed size to compute MB/s). Boot + run /root/validate.sh"
fi
