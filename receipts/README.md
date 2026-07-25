# receipts/ — committed raw results with full provenance

The proof. Every number this repo claims comes from a receipt here, reproduced from raw output. No receipt,
no claim. Each receipt pins: host stack (OS / kernel + `.config` hash / driver), benchmark stack (image vLLM
build, `llama-benchy` version, recipe permalink), the exact serve + measure commands, the raw output, the
comparison to the published number, and every confound.

| Receipt | Proves |
|---|---|
| `tier1-tier2-2026-06-09.txt` | Tiers 1–2: Rocky 10.2 + 6.18.34 boots; open driver builds/loads; GPU computes. |
| `proof-of-life-baremetal-2026-06-09.txt` | Tier 2.5: installed on the NVMe, reachable, GPU works from the bare-metal install. |
| `reproduce-Qwen3.5-35B-A3B-FP8-2026-06-10.txt` + `qwen3.5-35b-a3b-fp8-matrix-2026-06-10.csv` | Tier 3 (GPU-bound headline): full 104-cell `llama-benchy` matrix vs published; `tg128 (c1)`=56.2 vs 50.75, **median 1.01× across all cells = parity**. |
| `reproduce-Qwen3.5-0.8B-2026-06-10.txt` + `qwen3.5-0.8b-matrix-2026-06-10.csv` | Tier 3: full 104-cell matrix; `tg128 (c1)`=123.0 vs 121.2, **median 0.96× = parity**. |
| `reproduce-gemma-3-1b-it-2026-06-10.txt` + `gemma-3-1b-it-matrix-2026-06-10.csv` | Tier 3: 56-cell (context-capped) matrix; `tg128 (c1)`=101.9 vs 91.0, **median 1.05× = parity**. |
| `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt` + `qwen3.5-0.8b-matrix-gen2-2026-07-24.csv` | **Parity holds on the current runtime, on the shipped CLK kernel** (#71, subsuming #61's question): full matrix on `6.18.39-clk` + the pinned dgx-vllm mirror image (vLLM 0.23.1), **median 1.010× vs published** — decode 1.010×, prefill 1.011× (the June prefill deficit was runtime drift; #18 holds the localized residual). Throttle-check CLEAN. |

## How to read one

Top to bottom: what was reproduced (entry + URL + published number) → host stack → benchmark stack →
the exact recipe + commands → raw result → comparison → caveats. A stranger should be able to replay the
commands on the host stack and land within the stated spread. The standing confound on every cross-date
entry: spark-arena pins no vLLM version, so our build date vs the entry's submission date is a real
runtime-version difference (never the OS/kernel/driver). Since 2026-07-24 (#71) our side of that confound
is closed — receipts name a permanent dated mirror tag anyone can pull byte-identically.
