# receipts/ — committed raw results with full provenance

The proof. Every number this repo claims comes from a receipt here, reproduced from raw output. No receipt,
no claim. Each receipt pins: host stack (OS / kernel + `.config` hash / driver), benchmark stack (image vLLM
build, `llama-benchy` version, recipe permalink), the exact serve + measure commands, the raw output, the
comparison to the published number, and every confound.

| Receipt | Proves |
|---|---|
| `tier1-tier2-2026-06-09.txt` | Tiers 1–2: Rocky 10.2 + 6.18.34 boots; open driver builds/loads; GPU computes. |
| `proof-of-life-baremetal-2026-06-09.txt` | Tier 2.5: installed on the NVMe, reachable, GPU works from the bare-metal install. |
| `reproduce-LFM2.5-350M-2026-06-10.txt` | Tier 3 (first): `tg128 (c1)` = 246.0 vs published 222.77, exact recipe, pinned tools. |
| `reproduce-Qwen3.5-35B-A3B-FP8-2026-06-10.txt` + `…-matrix-2026-06-10.csv` | Tier 3 (GPU-bound headline): full 104-cell `llama-benchy` matrix vs published; `tg128 (c1)`=56.2 vs 50.75, **median 1.01× across all cells = parity**. |

## How to read one

Top to bottom: what was reproduced (entry + URL + published number) → host stack → benchmark stack →
the exact recipe + commands → raw result → comparison → caveats. A stranger should be able to replay the
commands on the host stack and land within the stated spread. The standing confound on every cross-date
entry: spark-arena pins no vLLM version, so our build date vs the entry's submission date is a real
runtime-version difference (never the OS/kernel/driver).
