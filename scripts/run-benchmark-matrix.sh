#!/bin/bash
# Run the canonical full llama-benchy matrix against a served model — the sweep behind the parity claim.
#
# This is deliverable #2's measurement step. It encodes the EXACT matrix (depth × prefill × decode ×
# concurrency, pinned llama-benchy 0.3.8) that produces the ~104-cell CSV compared to a published
# spark-arena entry. It is a script, not prose, on purpose: every reproduction and every regression-vs-self
# run must measure the SAME surface, or the comparison is meaningless.
#
# Run ON the box, after spark-vllm-docker is serving the model. Full pipeline: docs/benchmark/reproduce-pipeline.md.
# Usage: scripts/run-benchmark-matrix.sh <port> <hf-model> <out.csv>
set +e
PORT="${1:?usage: $0 <port> <hf-model> <out.csv>}"; MODEL="${2:?need an HF model path}"; OUT="${3:?need an output csv path}"

# Sibling-script resolver (audit #70 A3): prefer the repo checkout this script runs from; fall back to a
# /root copy. The 2026-07-23 #61 receipt went throttle-INDETERMINATE because a hardcoded /root/templog.sh
# picked up a stale June copy while the current sampler sat beside this script — never again.
HERE="$(cd "$(dirname "$0")" && pwd)"
sib() { if [ -x "$HERE/$1" ]; then echo "$HERE/$1"; elif [ -x "/root/$1" ]; then echo "/root/$1"; fi; }

# Wait for vLLM serve-ready; fail fast (and dump logs) if the container died.
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" = 200 ] && { echo "READY @ poll $i"; break; }
  docker ps --format '{{.Names}}' | grep -q vllm_node || { echo "DIED @ poll $i"; docker logs --tail 25 vllm_node 2>&1 | tail -25; exit 1; }
  echo "poll $i: loading"; sleep 10
done

# Auto-arm the forensic logger (templog) for the whole sweep, stopped on any exit. A benchmark must never run
# untraced: the 2026-06-11 crash had no thermal trace. (templog only observes; if a run thermally throttles,
# that is caught post-hoc from this trace -- the benchmark-integrity path -- not by a mid-run kill.)
TLOG="${OUT%.csv}-templog.csv"; TPID=""
trap '[ -n "$TPID" ] && kill "$TPID" 2>/dev/null' EXIT
TEMPLOG=$(sib templog.sh)
if [ -n "$TEMPLOG" ]; then "$TEMPLOG" 5 "$TLOG" & TPID=$!; echo "templog armed ($TEMPLOG) -> $TLOG (pid $TPID)"
else echo "WARNING: templog.sh absent (repo + /root) -- no forensic thermal trace for this run"; fi

echo "running the full canonical matrix for $MODEL ..."
# Canonical matrix: depth sweep 0..100000, prefill pp2048, decode tg128, concurrency 1/2/5/10, prefix caching.
# Do not change these without re-anchoring the parity comparison — they define "the full matrix".
UVX=$(command -v uvx || echo /root/.local/bin/uvx)
"$UVX" 'llama-benchy==0.3.8' --base-url "http://localhost:$PORT/v1" --model "$MODEL" \
  --depth 0 4096 8192 16384 32768 65535 100000 --pp 2048 --tg 128 \
  --enable-prefix-caching --concurrency 1 2 5 10 --save-result "$OUT" --format csv
rc=$?

# Fail closed (#42), part 1 -- command-level failure: a non-zero llama-benchy exit (OOM, GPU Xid 119, or the
# serving container dying) or a missing/header-only CSV is a dead run. (We keep `set +e` so the serve-ready
# poll loop above is unaffected; the bug was that the original never checked the exit code.) Discard it so the
# number never reaches a median or a receipt.
rows=$(wc -l < "$OUT" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ] || [ "${rows:-0}" -lt 2 ]; then
  [ -f "$OUT" ] && mv "$OUT" "$OUT.INVALIDATED"
  echo "MATRIX-INVALID: llama-benchy rc=$rc, $rows csv line(s) -> ${OUT}.INVALIDATED (run discarded)"
  exit 1
fi
# Fail closed (#42), part 2 -- completeness: the matrix is a rectangular depth x concurrency grid. A COMPLETE
# sweep has every requested concurrency level (the `--concurrency` arg above) present with the SAME cell
# count; a partial sweep that still exited 0 leaves a RAGGED grid -- a missing level, or unequal per-level
# counts. Model-INDEPENDENT: a model legitimately drops whole depths past its context (gemma 56 rows vs qwen
# 104), but a complete run is ALWAYS rectangular -- so no hardcoded row count and no model-context guess (which
# would fail-closed on good data). The concurrency level is the `(cN)` suffix on each test_name (col 2).
# NOTE: the want{1,2,5,10} set below MUST mirror the --concurrency arg above (a test invariant guards this).
read -r grid_ok cells_per < <(awk -F, '
  NR==1{next}
  match($2,/\(c[0-9]+\)/){ c=substr($2,RSTART+2,RLENGTH-3); cnt[c]++ }
  END{ want["1"]=want["2"]=want["5"]=want["10"]=1; ok=1; base=-1
       for(c in want){ if(!(c in cnt)) ok=0; else if(base<0) base=cnt[c]; else if(cnt[c]!=base) ok=0 }
       for(c in cnt){ if(!(c in want)) ok=0 }
       print ok, (base<0?0:base) }' "$OUT")
if [ "$grid_ok" != 1 ]; then
  mv "$OUT" "$OUT.INVALIDATED"
  echo "MATRIX-INVALID: ragged concurrency grid (need equal cells across c1,c2,c5,c10) -> ${OUT}.INVALIDATED (run discarded)"
  exit 1
fi
# Fail closed (#43) — thermal integrity: stop the templog trace, then scan it post-hoc. A thermally-throttled
# sweep's numbers are polluted; discard so they never reach a median/receipt. Post-hoc (not a mid-run kill) so
# it CANNOT false-trip a good run. Composes with the grid check above. check-throttle exit: 0 clean/warn,
# 1 throttled→discard, 3 indeterminate (no signal in trace)→keep+warn.
[ -n "$TPID" ] && { kill "$TPID" 2>/dev/null; TPID=""; sleep 1; }
CHKTHR=$(sib check-throttle.sh)
if [ -n "$CHKTHR" ] && [ -f "$TLOG" ]; then
  "$CHKTHR" "$TLOG"; thr=$?
  if [ "$thr" = 1 ]; then
    mv "$OUT" "$OUT.THROTTLED"
    echo "MATRIX-INVALID: GPU thermally throttled during the sweep -> ${OUT}.THROTTLED (run discarded, #43)"
    exit 1
  fi
fi
echo "MATRIX-DONE: $rows lines, ${cells_per} cells x c{1,2,5,10} -> $OUT"
