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
echo "ts,gpu_temp_c,gpu_tlimit_c,gpu_power_w,mem_used_g,hottest_zone_c,thermal_slowdown" > "$OUT"
echo "templog -> $OUT (every ${INT}s; stop with Ctrl-C / kill)"
while true; do
  # temp + power + the DEFINITIVE throttle signal (hw/sw thermal-slowdown reasons) in one query. The GB10 has
  # no absolute slowdown-temp spec (it uses the T.Limit-delta model), so the slowdown REASON is ground truth
  # for "did it throttle" — check-throttle.sh (#43) keys off this column post-run.
  IFS=, read -r gt gp hw sw < <(nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.sw_thermal_slowdown --format=csv,noheader,nounits 2>/dev/null | head -1)
  gt=${gt// /}; gp=${gp// /}; hw=${hw# }; sw=${sw# }
  thr=ok; { [ "$hw" = Active ] || [ "$sw" = Active ]; } && thr=THROTTLE
  # T.Limit headroom (degrees to throttle; 0 == throttling) — forensic proximity alongside the reason flag.
  tl=$(nvidia-smi -q -d TEMPERATURE 2>/dev/null | awk -F: '/GPU Current T.Limit Temp/{gsub(/[^0-9-]/,"",$2); print $2; exit}')
  m=$(free -g | awk '/^Mem:/{print $3}')
  z=$(awk '{print int($1/1000)}' /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1)
  echo "$(date +%H:%M:%S),${gt:-NA},${tl:-NA},${gp:-NA},${m:-NA},${z:-NA},${thr}" >> "$OUT"
  sleep "$INT"
done
