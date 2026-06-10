# Scoreboard — single-host, spark-arena vs spark-rocky

What the zero-patch stack (Rocky 10.2 + 6.18.34 + open 610) has reproduced, and what's next. Each target
maps to its recipe via [`reproduce-pipeline.md`](reproduce-pipeline.md) (`benchmarkId` → Firestore →
recipe permalink). Snapshot: `data/spark-arena-snapshot-2026-06-10.json`.

## Reproduced (committed receipts)

| model | scope | published | ours | result | receipt |
|---|---|---|---|---|---|
| LFM2.5-350M | `tg128 (c1)` | 222.8 | 246.0 ±0.3 | **+10.4%** | `reproduce-LFM2.5-350M-2026-06-10.txt` |
| Qwen3.5-35B-A3B-FP8 | `tg128 (c1)` | 50.75 | 56.2 ±0.1 | **+10.8%** | `reproduce-Qwen3.5-35B-A3B-FP8-2026-06-10.txt` |
| Qwen3.5-35B-A3B-FP8 | **full 104-cell matrix** | — | — | **median 1.01× = parity** | (same) |

The 35B full-matrix result is the honest headline: single-user decode ~1.10–1.11× (faster, flat across
context depth 0→100k); prefill ~0.75× and high-concurrency aggregate `tg128 c10` 0.73× (slower); **net
across 104 cells, median 1.01× — parity.** Not "Rocky is faster"; reproduced at parity, with the gains and
losses both attributable to the ~3-month vLLM-version drift (the one uncontrolled variable).

## Target backlog (top single-host `tg128 (c1)`, to reproduce next)

| model | published t/s | runtime | recipe | maps to issue |
|---|---|---|---|---|
| Qwen3.6-35B-A3B-NVFP4 | 218.8 | Atlas | sparkrun | #10 (Atlas) |
| Qwen3.6-35B-A3B-FP8 | 172.0 | Atlas | sparkrun | #10 (Atlas) |
| Qwen3.5-0.8B | 121.2 | vLLM | spark-vllm-docker | #5 (breadth) |
| Qwen3.6-35B-A3B-PrismaQuant-4.75bit | 95.1 | vLLM | spark-vllm-docker | #9 (faster-quant) |
| Qwen3.6-35B-A3B-int4-AutoRound | 92.3 | vLLM | spark-vllm-docker | #9 (faster-quant) |
| gemma-3-1b-it | 91.0 | vLLM | spark-vllm-docker | #5 (breadth) |
| gpt-oss-120b | 58.8 | vLLM | spark-vllm-docker | #6 (resurrect 120b) |

**Confound on every cross-date row:** spark-arena pins no vLLM version; our image's build date vs the
entry's submission date is a real runtime-version delta. Match the recipe `container:` tag to minimize it.
