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

echo "running the full canonical matrix for $MODEL ..."
# Canonical matrix: depth sweep 0..100000, prefill pp2048, decode tg128, concurrency 1/2/5/10, prefix caching.
# Do not change these without re-anchoring the parity comparison — they define "the full matrix".
/root/.local/bin/uvx 'llama-benchy==0.3.8' --base-url "http://localhost:$PORT/v1" --model "$MODEL" \
  --depth 0 4096 8192 16384 32768 65535 100000 --pp 2048 --tg 128 \
  --enable-prefix-caching --concurrency 1 2 5 10 --save-result "$OUT" --format csv
echo "MATRIX-DONE: $(wc -l < "$OUT" 2>/dev/null) lines -> $OUT"
