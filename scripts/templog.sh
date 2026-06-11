#!/bin/bash
# Passive thermal / power / memory sampler. Run ALONGSIDE a benchmark to capture a forensic trace:
#   ./templog.sh &                 # default: every 5s -> /root/templog-<epoch>.csv
#   ./templog.sh 2 /tmp/run.csv    # custom interval + path; Ctrl-C or kill to stop
# It only READS counters (nvidia-smi / free / thermal zones) — it does NOT touch the workload or throttle
# anything. Its whole purpose is visibility, so we can run the box full-tilt and SEE the thermals after the
# fact (the 2026-06-11 crash had no temperature trace).
set -uo pipefail
INT="${1:-5}"
OUT="${2:-/root/templog-$(date +%s).csv}"
echo "ts,gpu_temp_c,gpu_power_w,mem_used_g,hottest_zone_c" > "$OUT"
echo "templog -> $OUT (every ${INT}s; stop with Ctrl-C / kill)"
while true; do
  g=$(nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
  m=$(free -g | awk '/^Mem:/{print $3}')
  z=$(awk '{print int($1/1000)}' /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1)
  echo "$(date +%H:%M:%S),${g:-NA,NA},${m:-NA},${z:-NA}" >> "$OUT"
  sleep "$INT"
done
