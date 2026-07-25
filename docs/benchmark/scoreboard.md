# Scoreboard — single-host, spark-arena vs spark-rocky

The claim this page carries, in one line: **on this host — Rocky 10.2 + the CIQ Linux Kernel + the open
610 driver, zero patches — published spark-arena numbers come back at parity, and on the current
leaderboard meta the same host lands in the community band. Every time a number moved, the mover was
serving config, never the host.**

Three chapters, each with receipts.

## 1 — Parity: the host is invisible

Full-matrix medians vs published, `1.0× = parity` (June 2026 baseline; re-proven on the current
runtime 2026-07-24):

| model | scope | published `tg128 c1` | ours | full-matrix median | receipt |
|---|---|---|---|---|---|
| Qwen3.5-35B-A3B-FP8 | 104-cell matrix | 50.75 | 56.2 ±0.1 | **1.01× — parity** | `reproduce-Qwen3.5-35B-A3B-FP8-2026-06-10.txt` |
| Qwen3.5-0.8B | 104-cell matrix | 121.2 | 123.0 ±0.2 | **0.96× — parity** | `reproduce-Qwen3.5-0.8B-2026-06-10.txt` |
| gemma-3-1b-it | 56-cell matrix (context-capped) | 91.0 | 101.9 ±0.1 | **1.05× — parity** | `reproduce-gemma-3-1b-it-2026-06-10.txt` |
| Qwen3.5-0.8B — **current runtime, gen-2 pins** | 104-cell matrix on `6.18.39-clk` + the pinned dgx-vllm mirror (#71) | 121.2 | 124.1 ±0.1 | **1.010× — parity holds** (decode 1.010×, prefill 1.011×), throttle-check CLEAN | `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt` |

Medians spanning **0.96–1.05×** straddle parity — the signature of a transparent host swap. The June
prefill deficit (0.75–0.93×) closed to **1.011×** on the pinned current runtime: it was vLLM version
drift, not the host. One localized residual remains (single-user contextual `pp2048 (c1)` cells at
0.68–0.82×, [#18](https://github.com/maxspevack/spark-rocky/issues/18)). The runtime confound is closed
from our side: every current receipt names a **permanent dated
[`dgx-vllm`](https://github.com/spark-arena/dgx-vllm) mirror tag** anyone can pull byte-identically
([#71](https://github.com/maxspevack/spark-rocky/issues/71)); the residual delta on any cross-date
comparison is the *entry's* unpinned side. Not "faster"; reproduced at parity.

## 2 — The frontier: the current meta, in the community band

The leaderboard's current meta is **NVFP4 quantization + MTP speculative decoding** on vLLM nightlies.
Target: Qwen3.6-35B-A3B-NVFP4 + MTP ([#74](https://github.com/maxspevack/spark-rocky/issues/74)) —
community band **105–130** `tg128 (c1)`, board-best vLLM entry 118.9.

The first cut ran the official fp8-mtp recipe shape with the quant swapped to a compressed-tensors
NVFP4 checkpoint: **64 t/s**. A five-probe grid (single-cell `tg128(c1)@d0`, fresh serve per probe on
the pinned image, every probe throttle-CLEAN) decomposed the gap — and neither axis was the host:

| probe | config | `tg128(c1)@d0` | the move |
|---|---|---|---|
| control | `RedHatAI/` compressed-tensors NVFP4, official shape, nst=2 | 62.0 ±3.0 | baseline; thermal formally ruled out |
| format | **`nvidia/` ModelOpt NVFP4**, identical shape | 92.0 ±2.2 | **+48% — checkpoint format** |
| spec depth | + `num_speculative_tokens=3` | **109.1 ±4.8** | **+19% — in the band** |

The cutlass MoE backend was closed out with evidence: vLLM's NvFp4 oracle **rejects `VLLM_CUTLASS`**
for both checkpoints' quant schemes on the pinned build (engine-init failure, root cause preserved) —
the default autotuned FlashInfer `trtllm::fused_moe` path *is* the fast path. MTP engagement was
verified active throughout (acceptance length ~2.45 at nst=2, 3.17 at nst=3), so the format axis is not
a speculative-decoding artifact.

**Winner config, committed as
[`recipes/qwen3.6-35b-a3b-nvfp4-mtp-nst3-2026072302.yaml`](../../recipes/qwen3.6-35b-a3b-nvfp4-mtp-nst3-2026072302.yaml):**
`nvidia/Qwen3.6-35B-A3B-NVFP4`, official shape, nst=3, container pinned. The full v2 matrix on it
(28/28 cells, 2026-07-25) beats the first cut in **24/28 cells** (c1 lanes 1.57–1.83×, `d0 c10` at
384 t/s) — **indicative, not receipt: the #43 throttle gate discarded the run** (chapter 3). Fresh-serve
headline 109.1; pooled across both clean serves (N=6) ≈ 105.7. The receipt lands via the chunked
protocol below. Before any headline claim against the 118.9: **verify that entry's node count** — the
community's recipes for this model are predominantly dual-Spark (`tp=2`); ours is single-host by design.

Full probe-grid + matrix record: #74 (comments of 2026-07-25). The queue behind it:
[#73](https://github.com/maxspevack/spark-rocky/issues/73) (Nemotron-Super flagship — eugr's NVFP4 lane
is dual-node; the single-Spark shape is ours to prove),
[#75](https://github.com/maxspevack/spark-rocky/issues/75) (recipes upstreamed to the community
registry), [#76](https://github.com/maxspevack/spark-rocky/issues/76) (stretch).

## 3 — Discipline: why these numbers can be trusted

Every measured run on this box carries a 2-second thermal trace (`scripts/templog.sh`), and the
[#43](https://github.com/maxspevack/spark-rocky/issues/43) detector (`scripts/check-throttle.sh`)
issues a CLEAN/THROTTLED verdict post-hoc. **A THROTTLED run never becomes a receipt** — two full 35B
matrices have been discarded under this rule (2026-07-24, 2026-07-25). The structural fact behind both:
a ~55-minute sustained 35B sweep saturated the GB10's cooling in both attempts (mid-afternoon and
evening ambient) — the deep×concurrent tail alone holds the GPU at 82–88°C for ~25 minutes with
headroom exhausted — while single cells with cooldown gaps ran CLEAN throughout those same windows.
Even a clean-window cell inside a hot matrix reads ~6% below a fresh serve (the warm-box penalty: "no
throttle flag" ≠ cold). The receipt protocol for sustained sweeps is therefore **chunked**: the same v2 cells in
segments, cool-to-≤55°C gaps between segments, each segment's trace CLEAN, headline cells N≥5 on a
fresh serve.

gpt-oss-120b's full matrix stays parked behind the same cooling ceiling
([#6](https://github.com/maxspevack/spark-rocky/issues/6)); its single `tg128 (c1)` cell reproduced at
1.06× — recorded, but a single cell is below the parity bar.

Recipe mapping for any published entry: [`reproduce-pipeline.md`](reproduce-pipeline.md)
(`benchmarkId` → Firestore → recipe permalink). Board snapshot: `data/spark-arena-snapshot-2026-06-10.json`.
