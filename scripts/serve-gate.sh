#!/bin/bash
# serve-gate.sh — RELEASE GATE: prove the shipped kernel actually SERVES vLLM, not just vectorAdd.
#
# Why this exists: the 64k-page regression (#65) shipped silently in FOUR releases because release
# validation only ran a tiny `vectorAdd`. The Xid 31 MMU fault lives in the ~90 GB KV-cache allocation,
# which vectorAdd never touches. This gate exercises that exact path: it brings up the pinned vllm-node
# on the built kernel, waits for the engine to finish KV-cache allocation (`/health` 200), confirms the
# OpenAI API actually serves the model, and FAILS CLOSED on any container death / GPU fault / timeout.
#
# Run ON the GB10, on the kernel being released (after upgrade-metal + a clean reboot), BEFORE signing.
# A release is not signable until this prints GATE-PASS.
#
# Usage: serve-gate.sh [recipe] [port]   (default: qwen3.5-0.8b-arena 8000 — the cheapest full-serve)
set -uo pipefail
RECIPE="${1:-qwen3.5-0.8b-arena}"; PORT="${2:-8000}"
SVD="${SVD:-/root/spark-vllm-docker}"
LOG=/root/serve-gate.log
[ -d "$SVD" ] || { echo "GATE-FATAL: $SVD (spark-vllm-docker) missing — cannot serve-gate"; exit 1; }

echo "== serve-gate: kernel $(uname -r), pagesize $(getconf PAGESIZE), recipe $RECIPE =="
docker rm -f vllm_node >/dev/null 2>&1 || true
# Unified-memory preflight: on the GB10, cudaMemGetInfo reports host MemFree — page cache does NOT count,
# so a big docker pull right before the gate starves vLLM's startup check ("Free memory 23/121 GiB" while
# free -g shows 100+ available; hit live 2026-07-24, #71). Dropping caches is the community-standard fix
# and makes the gate deterministic regardless of what ran before it.
sync && echo 3 > /proc/sys/vm/drop_caches
# One cleanup, on EVERY exit path (audit #70 C11): an interrupted gate (Ctrl-C, dropped ssh) must not
# leave vllm_node serving ~90 GB of KV cache into the next build or benchmark.
trap 'docker rm -f vllm_node >/dev/null 2>&1 || true' EXIT
( cd "$SVD" && nohup ./run-recipe.sh "$RECIPE" --solo > "$LOG" 2>&1 & )

ok=0
for i in $(seq 1 45); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null || true)
  if [ "$code" = 200 ]; then ok=1; break; fi
  sleep 15
  if ! docker ps --format '{{.Names}}' | grep -q vllm_node; then
    echo "GATE-FAIL: serve container died after $((i*15))s — KV-cache/serve fault (the #65 class)."
    grep -iE "Xid|illegal memory|AcceleratorError|CUDA error|RuntimeError" "$LOG" 2>/dev/null | tail -4
    dmesg 2>/dev/null | grep -i "Xid" | tail -1
    exit 1
  fi
done

if [ "$ok" != 1 ]; then
  echo "GATE-FAIL: /health never reached 200 within the window (serve did not come up)."
  tail -5 "$LOG" 2>/dev/null
  exit 1
fi

# Past KV-cache allocation. Confirm the API actually serves (model listed) — a real serve, not just health.
# grep -c always prints a count (and exits 1 on zero) — no `|| echo 0`, which would append a second line
# and turn the -ge below into an "integer expression expected" fail-by-accident (audit #70 A4).
served=$(curl -s "http://localhost:$PORT/v1/models" 2>/dev/null | grep -c '"id"') || true
[ "$served" -ge 1 ] || { echo "GATE-FAIL: /health 200 but /v1/models served no model"; exit 1; }

echo "GATE-PASS: vLLM served on $(uname -r) ($(getconf PAGESIZE)-byte pages) — KV cache allocated, model on the API. Releasable."
