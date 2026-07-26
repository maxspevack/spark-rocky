#!/bin/bash
# #74 chunked receipt runner: ONE fresh serve, then the 28 official v2 cells as 11 segments
# (seg-00 = headline d0c1 at runs=5, first on the fresh serve), cool-to-<=55C gaps between
# segments, per-segment templog + #43 verdict, resume-state cleared per segment.
# Overall verdict CLEAN only if every segment is CLEAN and every bench rc=0.
set -uo pipefail
RECIPE="${1:?usage: $0 <recipe.yaml>}"
PIN="ghcr.io/spark-arena/dgx-vllm-eugr-nightly:2026072302"
OUT=/root/receipt-run
mkdir -p "$OUT"

teardown(){ ids=$(docker ps -aq --filter name=sparkrun); [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1; }
preserve(){ C=$(docker ps -q --filter name=sparkrun | head -1); [ -n "$C" ] && docker cp "$C":/tmp/sparkrun_serve.log "$OUT/serve-incontainer.log" >/dev/null 2>&1; }
cool(){ for i in $(seq 1 90); do t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1); [ "${t:-99}" -le 55 ] && return 0; sleep 5; done; }

sync && echo 3 > /proc/sys/vm/drop_caches
sparkrun run "$RECIPE" --hosts localhost --rootful --image "$PIN" --no-follow > "$OUT/serve.log" 2>sparkrun run "$RECIPE" --hosts localhost --rootful --image "$PIN" --no-follow > "$OUT/serve.log" 2>&1 \1 \
  || { echo LAUNCH-FAIL > "$OUT/verdict"; exit 1; }
READY=0
for i in $(seq 1 360); do
  curl -sf -m 3 http://localhost:8000/v1/models >/dev/null 2>&1 && READY=1 && break
  C=$(docker ps -q --filter name=sparkrun | head -1)
  [ -z "$C" ] && break
  docker exec "$C" grep -qE "EngineCore failed to start|vllm serve: error" /tmp/sparkrun_serve.log 2>/dev/null && break
  sleep 5
done
if [ "$READY" -ne 1 ]; then preserve; echo SERVE-FAIL > "$OUT/verdict"; teardown; exit 1; fi

ALL=CLEAN
for SEG in /root/seg-*.yaml; do
  N=$(basename "$SEG" .yaml)
  cool
  rm -rf /root/.cache/sparkrun/benchmarks
  /root/templog.sh 2 "$OUT/$N-templog.csv" >/dev/null 2>&1 &
  TL=$!
  sparkrun benchmark "$RECIPE" --hosts localhost --rootful --image "$PIN" \
    --profile "$SEG" --skip-run --output "$OUT/$N-results.yaml" > "$OUT/$N.log" 2>&1
  RC=$?
  kill "$TL" 2>/dev/null
  if ! /root/check-throttle.sh "$OUT/$N-templog.csv" > "$OUT/$N-throttle.txt" 2>&1; then ALL=DIRTY; fi
  [ "$RC" -ne 0 ] && ALL=DIRTY
  echo "$N rc=$RC $(head -c 120 "$OUT/$N-throttle.txt" | head -1)" >> "$OUT/progress"
done
preserve
teardown
echo "$ALL" > "$OUT/verdict"
