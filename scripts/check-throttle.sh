#!/bin/bash
# Post-hoc benchmark-integrity check (#43): scan a templog trace and decide whether the GPU thermally
# THROTTLED during the run. A throttled run's numbers are polluted and must never reach a median or a receipt.
# This is the post-hoc half of the old #25 watchdog (which was ripped out as the wrong tool): it kills nothing
# mid-run and CANNOT false-trip a good run — it only reads the trace templog.sh already captured.
#
# Signal (validated on the GB10, 2026-06-29): the box has NO absolute slowdown-temp spec — nvidia-smi uses the
# T.Limit-delta model. So the DEFINITIVE signal is the thermal-slowdown REASON (templog `thermal_slowdown`
# column: `THROTTLE` at any sample == the GPU was in thermal slowdown). T.Limit headroom (`gpu_tlimit_c`,
# degrees-to-throttle; 0 == throttling) is the forensic proximity: <=0 is a throttle, small-but-positive is a
# near-throttle WARN (numbers valid, box ran hot). Columns are found BY NAME from the header, so old templog
# format variants (e.g. a `gpu_tlimit` trace with no slowdown column) are handled — a trace carrying neither
# signal is reported INDETERMINATE (cannot certify), never a false PASS.
#
# Usage: scripts/check-throttle.sh <templog.csv> [near_throttle_warn_margin_c]
# Exit:  0 CLEAN (or near-throttle WARN — numbers kept) | 1 THROTTLED (discard) | 2 bad args | 3 INDETERMINATE
set -uo pipefail
TRACE="${1:?usage: $0 <templog.csv> [warn_margin_c]}"
MARGIN="${2:-5}"
[ -f "$TRACE" ] || { echo "THROTTLE-CHECK: FATAL — trace not found: $TRACE"; exit 2; }

hdr=$(head -1 "$TRACE")
col(){ printf '%s\n' "$hdr" | tr ',' '\n' | grep -nxF "$1" 2>/dev/null | head -1 | cut -d: -f1; }
c_slow=$(col thermal_slowdown)
c_tl=$(col gpu_tlimit_c); [ -z "$c_tl" ] && c_tl=$(col gpu_tlimit)
c_tmp=$(col gpu_temp_c);  [ -z "$c_tmp" ] && c_tmp=$(col gpu_temp)

if [ -z "$c_slow" ] && [ -z "$c_tl" ]; then
  echo "THROTTLE-CHECK: INDETERMINATE — $(basename "$TRACE") carries no throttle signal (no thermal_slowdown / gpu_tlimit column); cannot certify. Re-run with the current templog.sh."
  exit 3
fi

read -r verdict min_tl max_tmp slow_hits < <(awk -F, -v cs="$c_slow" -v ct="$c_tl" -v cp="$c_tmp" -v margin="$MARGIN" '
  NR==1 { next }
  {
    if (cs!="" && ($cs ~ /THROTTLE/ || $cs=="Active")) slow++   # NOT ~/Active/: "Not Active" would match (review NIT-7)
    if (ct!="" && $ct ~ /^-?[0-9]+$/) { v=$ct+0; if (mintl=="" || v<mintl) mintl=v }
    if (cp!="" && $cp ~ /^[0-9]+$/)    { t=$cp+0; if (t>maxt) maxt=t }
  }
  END {
    throttled = (slow>0) || (mintl!="" && mintl<=0)
    warn      = (mintl!="" && mintl<=margin && mintl>0)
    v = throttled ? "THROTTLED" : (warn ? "WARN" : "CLEAN")
    printf "%s %s %s %s\n", v, (mintl==""?"NA":mintl), (maxt==""?"NA":maxt), (slow+0)
  }' "$TRACE")

case "$verdict" in
  THROTTLED) echo "THROTTLE-CHECK: THROTTLED — slowdown samples=$slow_hits, min T.Limit headroom=${min_tl}C, max temp=${max_tmp}C. Discard this run."; exit 1 ;;
  WARN)      echo "THROTTLE-CHECK: CLEAN (WARN: near-throttle — min T.Limit headroom=${min_tl}C <= ${MARGIN}C; max temp=${max_tmp}C). Numbers kept; box ran hot."; exit 0 ;;
  *)         echo "THROTTLE-CHECK: CLEAN — no thermal slowdown; min T.Limit headroom=${min_tl}C, max temp=${max_tmp}C."; exit 0 ;;
esac
