#!/bin/bash
# Fail-closed thermal watchdog (#25). Watches the GPU and the hottest thermal zone during a serve; if
# either crosses a self-calibrated ceiling — OR if it cannot read the sensors — it SIGTERMs the serve
# container, records why, and exits non-zero. It NEVER reboots: "stopped, safe", not "degraded, come fix me".
#
# Why it trips BELOW the hardware's limit: the GB10 throttles itself, so the risk isn't damage — it's a run
# silently entering thermal throttle and producing INVALID benchmark numbers. So the trip line is the
# hardware's own SLOWDOWN temp minus a margin: kill before the data goes bad. templog.sh only observes;
# the 2026-06-11 crash proved observation is not enough.
#
# The threshold is DERIVED from the hardware (nvidia-smi slowdown temp; /sys critical trip points), never
# hardcoded — it survives a silicon swap. MARGIN (degrees below the hardware line) is the one tunable.
#
# Usage:
#   ./thermal-watchdog.sh                       # watch 'vllm_node', 5s interval, MARGIN=5
#   CONTAINER=foo INTERVAL=2 MARGIN=8 ./thermal-watchdog.sh
#   ./thermal-watchdog.sh --self-test           # verify read path + trip logic (no kill); run by validate.sh
set -uo pipefail
MARGIN="${MARGIN:-5}"
INTERVAL="${INTERVAL:-5}"
CONTAINER="${CONTAINER:-vllm_node}"
LOG="${LOG:-/root/thermal-watchdog-$(date +%s 2>/dev/null || echo run).log}"

# --- reads (templog.sh's read path) ------------------------------------------------------------------
gpu_temp(){ nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9'; }
gpu_slowdown(){ nvidia-smi -q -d TEMPERATURE 2>/dev/null | awk -F: '/GPU Slowdown Temp/{gsub(/[^0-9]/,"",$2);print $2;exit}'; }
hottest_zone(){ awk '{print int($1/1000)}' /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -1; }
# the self-calibrated zone ceiling = lowest critical/hot trip across all zones (empty if none expose one)
zone_crit(){
  local lo="" v
  for tp in /sys/class/thermal/thermal_zone*/trip_point_*_type; do
    [ -f "$tp" ] || continue
    case "$(cat "$tp" 2>/dev/null)" in
      critical|hot)
        v=$(cat "${tp%_type}_temp" 2>/dev/null); [ -n "$v" ] || continue; v=$((v/1000))
        if [ -z "$lo" ] || [ "$v" -lt "$lo" ]; then lo=$v; fi ;;
    esac
  done
  echo "$lo"
}

# --- pure trip decision: echoes "TRIP <reason>" or "OK ..." given the readings -----------------------
# args: gpu_temp gpu_slowdown zone_temp zone_crit margin
decide(){
  local gt="$1" gs="$2" zt="$3" zc="$4" m="$5"
  # fail-closed: the authoritative metric (GPU temp + slowdown) MUST be readable, or we stop rather than run blind
  if [ -z "$gt" ] || [ -z "$gs" ]; then echo "TRIP fail-closed: GPU sensor unreadable (temp='$gt' slowdown='$gs')"; return; fi
  if [ "$gt" -ge $(( gs - m )) ]; then echo "TRIP GPU ${gt}C >= slowdown ${gs}C - margin ${m}C"; return; fi
  if [ -n "$zt" ] && [ -n "$zc" ] && [ "$zt" -ge $(( zc - m )) ]; then echo "TRIP zone ${zt}C >= critical ${zc}C - margin ${m}C"; return; fi
  echo "OK gpu=${gt}/${gs} zone=${zt:-NA}/${zc:-NA} margin=${m}"
}

# --- self-test: symmetric verification (calibration #5), no container is touched ---------------------
self_test(){
  local gt gs zt zc rc=0
  gt=$(gpu_temp); gs=$(gpu_slowdown); zt=$(hottest_zone); zc=$(zone_crit)
  echo "read: gpu_temp=${gt:-NA} gpu_slowdown=${gs:-NA} hottest_zone=${zt:-NA} zone_crit=${zc:-NA}"
  # a) read path intact (the regression a kernel/driver bump would silently break)
  if [ -n "$gt" ] && [ -n "$gs" ]; then echo "  [PASS] read path: GPU temp + slowdown"; else echo "  [FAIL] GPU read path broken"; rc=1; fi
  # b) legitimate path: real readings at the real margin must NOT trip a normal run
  case "$(decide "$gt" "$gs" "$zt" "$zc" "$MARGIN")" in OK*) echo "  [PASS] cool path does not false-trip";; *) echo "  [FAIL] would kill a normal run"; rc=1;; esac
  # c) adversarial path: an absurd margin must force a trip (proves the kill path fires)
  case "$(decide "$gt" "$gs" "$zt" "$zc" 500)" in TRIP*) echo "  [PASS] hot path trips";; *) echo "  [FAIL] over-threshold did not trip"; rc=1;; esac
  # d) fail-closed path: an unreadable GPU sensor must trip
  case "$(decide "" "" "$zt" "$zc" "$MARGIN")" in TRIP\ fail-closed*) echo "  [PASS] fail-closed on unreadable sensor";; *) echo "  [FAIL] ran blind instead of failing closed"; rc=1;; esac
  if [ "$rc" = 0 ]; then echo "SELF-TEST: PASS"; else echo "SELF-TEST: FAIL"; fi
  return $rc
}

[ "${1:-}" = "--self-test" ] && { self_test; exit $?; }

# --- watch loop --------------------------------------------------------------------------------------
echo "thermal-watchdog: container=$CONTAINER interval=${INTERVAL}s margin=${MARGIN}C -> $LOG"
echo "ts,gpu_temp,gpu_slowdown,hottest_zone,zone_crit,verdict" > "$LOG"
while true; do
  gt=$(gpu_temp); gs=$(gpu_slowdown); zt=$(hottest_zone); zc=$(zone_crit)
  v=$(decide "$gt" "$gs" "$zt" "$zc" "$MARGIN")
  echo "$(date +%H:%M:%S 2>/dev/null || echo NA),${gt:-NA},${gs:-NA},${zt:-NA},${zc:-NA},${v}" >> "$LOG"
  case "$v" in
    TRIP*)
      echo "!! $v"
      echo "!! SIGTERM $CONTAINER — stopped, safe (NOT rebooting). reason logged: $LOG"
      docker kill --signal=TERM "$CONTAINER" 2>/dev/null || docker stop "$CONTAINER" 2>/dev/null || true
      echo "$(date 2>/dev/null || echo NA) STOPPED $CONTAINER: $v" >> "$LOG"
      exit 3 ;;
  esac
  sleep "$INTERVAL"
done
