#!/bin/bash
# One command to answer one question: does this stack actually work on YOUR Spark?
# Boot the USB, log in, and run:  /root/validate.sh
# It checks the kernel, the open NVIDIA driver, the GPU, and runs a real CUDA kernel on the
# hardware, then prints a single PASS/FAIL plus the exact text to drop into a report.
set -uo pipefail
ISSUE="https://github.com/maxspevack/spark-rocky/issues/11"
line(){ printf '%s\n' "============================================================"; }
line; echo " spark-rocky · does the stack come up on this box?"; line
FAIL=0

K=$(uname -r); echo "kernel:         $K"
OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"); echo "os:             $OS"
DRV=$(modinfo nvidia 2>/dev/null | awk -F: '/^version:/{gsub(/[[:space:]]/,"",$2);print $2}')
echo "nvidia driver:  ${DRV:-NOT LOADED}"
[ -n "$DRV" ] || { echo "  !! nvidia kernel module not loaded"; FAIL=1; }

echo "--- nvidia-smi ---"
if ! nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null; then
  echo "  !! nvidia-smi failed"; FAIL=1
fi

echo "--- CUDA compute on the GPU ---"
if [ -x /root/proof-of-life.sh ]; then
  /root/proof-of-life.sh >/tmp/pol.log 2>&1
  tail -3 /tmp/pol.log
  # proof-of-life.sh runs `set +e` and always exits 0 — trust its verdict STRING, not its rc,
  # or a failed CUDA run would slip through as PASS.
  grep -q "CUDA COMPUTE: PASS" /tmp/pol.log || { echo "  !! GPU CUDA check did NOT pass (full log: /tmp/pol.log)"; FAIL=1; }
else
  echo "  !! proof-of-life.sh not present in this image — cannot run the GPU CUDA check"; FAIL=1
fi

line
if [ "$FAIL" = 0 ]; then
  echo " RESULT: PASS"
  echo " Rocky + stock kernel $K + open driver $DRV drives the GB10 on this box."
  echo " It worked — please say so on the issue (one line is plenty):"
else
  echo " RESULT: FAIL"
  echo " Something above did not come up. This is exactly the bug worth filing —"
  echo " please paste everything above into a new issue:"
fi
echo "   $ISSUE"
line
