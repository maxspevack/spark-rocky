# Scoreboard — single-host, spark-arena vs spark-rocky

What the zero-patch stack (Rocky 10.2 + stock 6.18 + open 610) has reproduced, and what's next. The shipped stack is now **6.18.35** (64k pages); the parity receipts below were benched on 6.18.34/4k (the 64k page-size win is in [`../build/platform-deltas.md`](../build/platform-deltas.md)). Each target
maps to its recipe via [`reproduce-pipeline.md`](reproduce-pipeline.md) (`benchmarkId` → Firestore →
recipe permalink). Snapshot: `data/spark-arena-snapshot-2026-06-10.json`.

## Reproduced (committed receipts)

| model | scope | published `tg128 c1` | ours | full-matrix result | receipt |
|---|---|---|---|---|---|
| LFM2.5-350M | `tg128 (c1)` only | 222.8 | 246.0 ±0.3 | (single cell) +10.4% | `reproduce-LFM2.5-350M-2026-06-10.txt` |
| Qwen3.5-35B-A3B-FP8 | full 104-cell matrix | 50.75 | 56.2 ±0.1 | **median 1.01× = parity** | `reproduce-Qwen3.5-35B-A3B-FP8-2026-06-10.txt` |
| Qwen3.5-0.8B | full 104-cell matrix | 121.2 | 123.0 ±0.2 | **median 0.96× = parity** | `reproduce-Qwen3.5-0.8B-2026-06-10.txt` |
| gemma-3-1b-it | 56-cell matrix (context-capped) | 91.0 | 101.9 ±0.1 | **median 1.05× = parity** | `reproduce-gemma-3-1b-it-2026-06-10.txt` |
| gpt-oss-120b | `tg128 (c1)` | 58.8 | 62.6 ±0.0 | **single cell** 1.06× — full matrix gated by this desk box's cooling, not the stack (see #6) | single-cell |

The consistent shape across the **three full-matrix** models (Qwen-35B, Qwen-0.8B, gemma): single-user
**decode** runs at or slightly above parity, **prefill** runs slower (~0.75–0.93×), and the full-matrix
**median lands on parity (0.96–1.05×)**. The two **single-cell** results (LFM2.5-350M, gpt-oss-120b) measure
`tg128 (c1)` only — a full matrix is the bar for a parity claim. The per-axis deltas track the vLLM-version
drift (the one uncontrolled variable — spark-arena pins no runtime version), not the OS/kernel swap. Not
"faster"; reproduced at parity.

## Target backlog (top single-host entries, to reproduce next)

| model | published t/s | runtime | recipe | maps to issue |
|---|---|---|---|---|
| Qwen3.6-35B-A3B-NVFP4 | 218.8 | Atlas | sparkrun | #10 (Atlas) / #17 (NVFP4) |
| Qwen3.6-35B-A3B-FP8 | 172.0 | Atlas | sparkrun | #10 (Atlas) |
| Qwen3.6-35B-A3B-PrismaQuant-4.75bit | 95.1 | vLLM | spark-vllm-docker | #9 (faster-quant) |
| Qwen3.6-35B-A3B-int4-AutoRound | 92.3 | vLLM | spark-vllm-docker | #9 (faster-quant) |

**Confound on every cross-date row:** spark-arena pins no vLLM version; our image's build date vs the
entry's submission date is a real runtime-version delta. Match the recipe `container:` tag to minimize it.
