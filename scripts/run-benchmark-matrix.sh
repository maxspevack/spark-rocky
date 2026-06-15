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

# Wait for vLLM serve-ready; fail fast (and dump logs) if the container died.
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" = 200 ] && { echo "READY @ poll $i"; break; }
  docker ps --format '{{.Names}}' | grep -q vllm_node || { echo "DIED @ poll $i"; docker logs --tail 25 vllm_node 2>&1 | tail -25; exit 1; }
  echo "poll $i: loading"; sleep 10
done

# Auto-arm the forensic logger (templog) + the fail-closed thermal guard (#25) for the whole sweep, and
# stop both however we exit. A benchmark must never run untraced or unguarded: the 2026-06-11 crash had no
# thermal trace, and an over-temp run records throttled (invalid) numbers. The tools are absent only OFF the
# box, so warn loudly rather than silently running bare.
TLOG="${OUT%.csv}-templog.csv"; TPID=""; WPID=""
trap '[ -n "$TPID" ] && kill "$TPID" 2>/dev/null; [ -n "$WPID" ] && kill "$WPID" 2>/dev/null' EXIT
if [ -x /root/templog.sh ]; then /root/templog.sh 5 "$TLOG" & TPID=$!; echo "templog armed -> $TLOG (pid $TPID)"
else echo "WARNING: /root/templog.sh absent -- no forensic thermal trace for this run"; fi
if [ -x /root/thermal-watchdog.sh ]; then /root/thermal-watchdog.sh & WPID=$!; echo "thermal-watchdog armed (pid $WPID)"
else echo "WARNING: /root/thermal-watchdog.sh absent -- running UNGUARDED (no over-temp protection)"; fi

echo "running the full canonical matrix for $MODEL ..."
# Canonical matrix: depth sweep 0..100000, prefill pp2048, decode tg128, concurrency 1/2/5/10, prefix caching.
# Do not change these without re-anchoring the parity comparison — they define "the full matrix".
/root/.local/bin/uvx 'llama-benchy==0.3.8' --base-url "http://localhost:$PORT/v1" --model "$MODEL" \
  --depth 0 4096 8192 16384 32768 65535 100000 --pp 2048 --tg 128 \
  --enable-prefix-caching --concurrency 1 2 5 10 --save-result "$OUT" --format csv
rc=$?

# Fail closed (#42): a partial/aborted sweep must NOT pass as a clean matrix. A non-zero llama-benchy exit
# -- OOM, GPU Xid 119, the serving container dying, or the #25 thermal watchdog SIGTERMing it mid-run -- or a
# missing/header-only CSV, is a dead run. Discard it so the number never reaches a median or a receipt.
# (We keep `set +e` so the serve-ready poll loop above is unaffected; the actual bug was that the original
# never checked the exit code.) An exact per-model cell-count assertion is a follow-up: the expected row count
# is model-dependent -- depth cells past a model's context are dropped (gemma=56 vs qwen=104 rows) -- so it
# must be derived from the args + model context, never a hardcoded literal.
rows=$(wc -l < "$OUT" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ] || [ "${rows:-0}" -lt 2 ]; then
  [ -f "$OUT" ] && mv "$OUT" "$OUT.INVALIDATED"
  echo "MATRIX-INVALID: llama-benchy rc=$rc, $rows csv line(s) -> ${OUT}.INVALIDATED (run discarded)"
  exit 1
fi
echo "MATRIX-DONE: $rows lines -> $OUT"
