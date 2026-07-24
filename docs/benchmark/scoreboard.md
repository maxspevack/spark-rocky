# Scoreboard — single-host, spark-arena vs spark-rocky

What the zero-patch stack (Rocky 10.2 + the open 610 driver + an unmodified 6.18 kernel — CLK the shipped default, stock kernel.org the A/B) has reproduced, and what's next. The shipped stack is **6.18.39-clk** (4k pages, released 2026-07-23 — a routine 6.18.y stable bump over the benchmarked `.38`, serve-gated), and its predecessor kernel is **benchmark-validated at parity** — the Qwen3.5-0.8B full matrix on 6.18.38-clk/4k lands **median 1.007× vs the June stock-host baseline** (all 104 cells; receipt: [`reproduce-Qwen3.5-0.8B-clk4k-2026-07-23.txt`](../../receipts/reproduce-Qwen3.5-0.8B-clk4k-2026-07-23.txt), #61), so CLK reproduces the published numbers, not just the stock host. One honest caveat rides that receipt: the CLK/4k run is **directional-strong, not throttle-certified** — its templog trace carried no throttle column (see the receipt's CAVEAT section). **The shipped `.39-clk` now carries its own full-matrix receipt (2026-07-24, throttle-check CLEAN): the current pinned runtime lands median 1.010× vs published** — see the generation-2 row below. The older receipts below were benched on 6.18.34/4k — same page size. 64k was reverted 2026-07-17 (a serve regression, [#65](https://github.com/maxspevack/spark-rocky/issues/65); the historical 64k win is in [`../build/platform-deltas.md`](../build/platform-deltas.md)). Each target
maps to its recipe via [`reproduce-pipeline.md`](reproduce-pipeline.md) (`benchmarkId` → Firestore →
recipe permalink). Snapshot: `data/spark-arena-snapshot-2026-06-10.json`.

## Reproduced (committed receipts)

| model | scope | published `tg128 c1` | ours | full-matrix result | receipt |
|---|---|---|---|---|---|
| LFM2.5-350M | `tg128 (c1)` only | 222.8 | 246.0 ±0.3 | (single cell) +10.4% | `reproduce-LFM2.5-350M-2026-06-10.txt` |
| Qwen3.5-35B-A3B-FP8 | full 104-cell matrix | 50.75 | 56.2 ±0.1 | **median 1.01× = parity** | `reproduce-Qwen3.5-35B-A3B-FP8-2026-06-10.txt` |
| Qwen3.5-0.8B | full 104-cell matrix | 121.2 | 123.0 ±0.2 | **median 0.96× = parity** | `reproduce-Qwen3.5-0.8B-2026-06-10.txt` |
| gemma-3-1b-it | 56-cell matrix (context-capped) | 91.0 | 101.9 ±0.1 | **median 1.05× = parity** | `reproduce-gemma-3-1b-it-2026-06-10.txt` |
| gpt-oss-120b | `tg128 (c1)` | 58.8 | 62.6 ±0.0 | **single cell** 1.06× — full matrix **parked** (#6; gated by this desk box's cooling, not the stack) | single-cell |
| Qwen3.5-0.8B **(current runtime, gen-2 pins)** | full 104-cell matrix on `6.18.39-clk` + the pinned dgx-vllm mirror image (#71) | 121.2 | 124.1 ±0.1 | **median 1.010× vs published = parity holds on the current runtime** (decode 1.010×, prefill 1.011×) | `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt` |

The consistent shape across the **three June full-matrix** models (Qwen-35B, Qwen-0.8B, gemma): single-user
**decode** at or slightly above parity, **prefill** slower (~0.75–0.93×), full-matrix
**median on parity (0.96–1.05×)**. The two **single-cell** results (LFM2.5-350M, gpt-oss-120b) measure
`tg128 (c1)` only — a full matrix is the bar for a parity claim. The June prefill deficit is now
**proven to be vLLM-version drift, not the host**: on the current pinned runtime (gen-2 row above) the
prefill median vs published moves 0.75–0.93× → **1.011×**. The runtime variable itself is no longer
uncontrolled on our side — the image is pinned to a permanent dated mirror tag (#71). What remains is one
localized residual (single-user contextual `pp2048 (c1)` cells at 0.77–0.82×, [#18](https://github.com/maxspevack/spark-rocky/issues/18)).
Not "faster"; reproduced at parity.

## Target backlog — historical snapshot (2026-06-10 entries; the live queue is #71–#76)

> The rows below are the June snapshot's top entries, kept for the recipe mapping. The **live**
> benchmark queue (2026-07-23) is [#73](https://github.com/maxspevack/spark-rocky/issues/73) (Nemotron
> flagship) and [#74](https://github.com/maxspevack/spark-rocky/issues/74) (Qwen3.6 NVFP4+MTP —
> supersedes #9/#17), with the harness/serving-stack work in #71/#72 and the community-recipe path in
> #75/#76.

| model | published t/s | runtime | recipe | status (2026-07-24) |
|---|---|---|---|---|
| Qwen3.6-35B-A3B-NVFP4 | 218.8 | Atlas | sparkrun | Atlas closed **won't-adopt** (#10 — its board prefill entries are measurement artifacts); the NVFP4+MTP vLLM lane is **#74** (board-best vLLM: 118.9, 2026-06-30) |
| Qwen3.6-35B-A3B-FP8 | 172.0 | Atlas | sparkrun | same — #10 closed; FP8+MTP rides #74's comparison set |
| Qwen3.6-35B-A3B-PrismaQuant-4.75bit | 95.1 | vLLM | spark-vllm-docker | #9 closed, superseded by **#74** |
| Qwen3.6-35B-A3B-int4-AutoRound | 92.3 | vLLM | spark-vllm-docker | #9 closed, superseded by **#74** |

**Confound on every cross-date row:** spark-arena pins no vLLM version; our image's build date vs the
entry's submission date is a real runtime-version delta. **Closed from our side (#71):** our images pin
permanent dated [`dgx-vllm`](https://github.com/spark-arena/dgx-vllm) mirror tags, so every receipt names a
runtime any third party can pull byte-identically; the residual delta is the *entry's* unpinned side.
