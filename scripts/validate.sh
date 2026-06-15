#!/bin/bash
# spark-rocky DOCTOR — one command to prove the whole box came up as we built it.
# Boot the image (USB or installed NVMe), log in, and run:  /root/validate.sh
#
# It proves four things and prints one PASS/FAIL plus the text to paste into an issue:
#   1. provenance  — this IS a spark-rocky image, and it booted the kernel + driver we built
#   2. the stack   — open NVIDIA driver loaded, nvidia-smi works, a real CUDA kernel runs on the GPU
#   3. the guard   — the #25 thermal-watchdog self-test passes (read path + trip logic + fail-closed)
#   4. boot hygiene— the properties that make the image clean + fast are actually ACTIVE at runtime
set -uo pipefail
ISSUE="https://github.com/maxspevack/spark-rocky/issues/new"
REL=/etc/spark-rocky-release
line(){ printf '%s\n' "============================================================"; }
sect(){ echo; echo "--- $1 ---"; }
FAIL=0
chk(){ if eval "$1" >/dev/null 2>&1; then echo "  ok: $2"; else echo "  !! $2"; FAIL=1; fi; }

line; echo " spark-rocky doctor · did this box come up as we built it?"; line

sect "1. provenance (what this image claims to be)"
EXP_K=""; EXP_D=""
if [ -f "$REL" ]; then
  sed 's/^/  /' "$REL"
  EXP_K=$(awk -F= '/^kernel=/{print $2}' "$REL")
  EXP_D=$(awk -F= '/^driver=/{print $2}' "$REL")
else
  echo "  !! $REL absent — cannot confirm this is a spark-rocky image"; FAIL=1
fi

sect "2. kernel + OS + open NVIDIA driver"
K=$(uname -r);  echo "  kernel:        $K"
OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"); echo "  os:            $OS"
DRV=$(modinfo nvidia 2>/dev/null | awk -F: '/^version:/{gsub(/[[:space:]]/,"",$2);print $2}')
echo "  nvidia driver: ${DRV:-NOT LOADED}"
chk '[ -n "$DRV" ]' "nvidia kernel module loaded"
[ -z "$EXP_K" ] || chk '[ "$K" = "$EXP_K" ]'   "running kernel matches the built kernel ($EXP_K)"
[ -z "$EXP_D" ] || chk '[ "$DRV" = "$EXP_D" ]' "running driver matches the built driver ($EXP_D)"

sect "3. nvidia-smi"
if nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  /'; then :
else echo "  !! nvidia-smi failed"; FAIL=1; fi

sect "4. CUDA compute on the GPU"
if [ -x /root/proof-of-life.sh ]; then
  /root/proof-of-life.sh >/tmp/pol.log 2>&1; tail -3 /tmp/pol.log | sed 's/^/  /'
  # trust the verdict STRING, not the rc — proof-of-life runs `set +e` and always exits 0
  grep -q "CUDA COMPUTE: PASS" /tmp/pol.log || { echo "  !! GPU CUDA check did NOT pass (full log: /tmp/pol.log)"; FAIL=1; }
else echo "  !! proof-of-life.sh not present — cannot run the GPU CUDA check"; FAIL=1; fi

sect "5. thermal watchdog self-test (#25 safety primitive)"
if [ -x /root/thermal-watchdog.sh ]; then
  /root/thermal-watchdog.sh --self-test >/tmp/twd.log 2>&1; tail -6 /tmp/twd.log | sed 's/^/  /'
  grep -q "SELF-TEST: PASS" /tmp/twd.log || { echo "  !! thermal-watchdog self-test did NOT pass (full log: /tmp/twd.log)"; FAIL=1; }
else echo "  !! thermal-watchdog.sh not present — the benchmark safety primitive is missing"; FAIL=1; fi

sect "6. boot hygiene (the properties that make the image clean + fast)"
chk 'grep -q nvidia-drm.modeset=0 /proc/cmdline' "nvidia-drm.modeset=0 active (no WQ_UNBOUND flood / console blackout)"
chk '! lsmod | grep -q "^mlx5_core"'             "mlx5_core not loaded (blacklisted — no missing-firmware dmesg flood)"
SWAP=$(awk '/^SwapTotal/{print $2}' /proc/meminfo 2>/dev/null)
chk '[ "${SWAP:-1}" = 0 ]'                       "swap is off (was ${SWAP:-?} kB; GB10 swap-on-overcommit hang prevention)"
NOISE=$(dmesg 2>/dev/null | grep -ciE 'mlx5.*(firmware|insufficient power)|WQ_UNBOUND')
chk '[ "${NOISE:-1}" = 0 ]'                      "dmesg clean of the known regressions (mlx5-firmware / WQ_UNBOUND): ${NOISE:-?} hit(s)"

line
if [ "$FAIL" = 0 ]; then
  echo " RESULT: PASS"
  echo " Rocky + stock kernel $K + open driver $DRV drives the GB10 on this box, and the image is clean."
  echo " It worked — please open a quick issue to let us know (one line is plenty):"
else
  echo " RESULT: FAIL"
  echo " Something above did not come up as expected. This is exactly the bug worth filing —"
  echo " please paste everything above into a new issue:"
fi
echo "   $ISSUE"
line
