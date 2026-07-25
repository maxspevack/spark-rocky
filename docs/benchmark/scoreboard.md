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
NVFP4 checkpoint: **64 t/s**. A probe grid (single-cell `tg128(c1)@d0`, fresh serve per probe on the
pinned image, every probe throttle-CLEAN) decomposed the gap — and no axis was the host:

| probe | config | `tg128(c1)@d0` | the move |
|---|---|---|---|
| control | `RedHatAI/` compressed-tensors NVFP4, official shape, nst=2 | 62.0 ±3.0 | baseline; thermal formally ruled out |
| format | **`nvidia/` ModelOpt NVFP4**, identical shape | 92.0 ±2.2 | **+48% — checkpoint format** |
| spec depth | + `num_speculative_tokens=3` | 109.1 ±4.8 | **+19% — in the band** |
| board lane | the board's own recipe: + marlin MoE, async-scheduling, triton draft | **118.3 ±8.0** | +8% — brackets board-best on a good run |

The cutlass MoE backend was closed out with evidence: vLLM's NvFp4 oracle **rejects `VLLM_CUTLASS`**
for both checkpoints' quant schemes on the pinned build (engine-init failure, root cause preserved).
MTP engagement was verified active throughout (acceptance length ~2.45 at nst=2, 3.17–3.19 at nst=3),
so the format axis is not a speculative-decoding artifact.

**The receipt (2026-07-25, the first through chapter 3's chunked protocol):** all 28 official v2
cells on the board-lineage config
([`recipes/qwen3.6-35b-a3b-nvfp4-board-2026072302.yaml`](../../recipes/qwen3.6-35b-a3b-nvfp4-board-2026072302.yaml)
— the exact recipe behind the board's two top vLLM entries, flag semantics verbatim), **zero throttle
samples across the sweep** (11 segments CLEAN; four deep segments are honest near-throttle WARNs).
Headline `tg128 (c1)` at N=5 on the fresh serve: **100.1 ± 6.2**. Full table + raw values:
[`receipts/reproduce-Qwen3.6-35B-A3B-NVFP4-mtp-2026-07-25.txt`](../../receipts/reproduce-Qwen3.6-35B-A3B-NVFP4-mtp-2026-07-25.txt).

**Run variance is the honest headline at c1.** Clean-run per-serve means on this host span
**100.1–118.3** on the identical board config, and the board's own single-node vLLM field for this
model spans **105.1–118.9** (live snapshot 2026-07-25; every entry `cluster=1` — verified, and
dual-node entries run *lower*). Same center, same spread structure: the board-best 118.91 and our
118.3 probe are the same phenomenon — a favorable run of a high-variance config — not a configuration
gap. Parity with the field, receipt-grade. Two config notes with teeth: the board recipe's
`max-num-seqs 4` deliberately caps the concurrency cells (our nst=3/default-MoE config measured
`d0 c10` at 384 t/s indicative vs 174 here — it is a single-user-lane specialist), and the published
v1 recipe does not run under sparkrun 0.2.40 as-is (`{{…}}` escaping; the committed variant is the
syntax-only conversion).

Full probe-grid + receipt record: #74. The queue behind it:
[#73](https://github.com/maxspevack/spark-rocky/issues/73) (Nemotron-Super flagship — eugr's NVFP4 lane
is dual-node; the single-Spark shape is ours to prove),
[#75](https://github.com/maxspevack/spark-rocky/issues/75) (recipes upstreamed to the community
registry), [#76](https://github.com/maxspevack/spark-rocky/issues/76) (stretch).

## 3 — Discipline: why these numbers can be trusted

Every measured run on this box carries a 2-second thermal trace (`scripts/templog.sh`), and the
[#43](https://github.com/maxspevack/spark-rocky/issues/43) detector (`scripts/check-throttle.sh`)
issues a CLEAN/THROTTLED verdict post-hoc. **A THROTTLED run never becomes a receipt** — two full 35B
matrices have been discarded under this rule (2026-07-24, 2026-07-25). The structural fact behind both:
**cooling saturation tracks the duration of sustained load, not the clock.** A ~55-minute continuous
sweep saturates — the deep×concurrent tail alone holds the GPU at 82–88°C for ~25 minutes with
headroom exhausted — while single cells with cooldown gaps ran CLEAN at every hour tested. The box
runs indoors at effectively constant ambient; time-of-day is not a variable in these results.
Even a clean-window cell inside a hot matrix reads ~6% below a fresh serve (the warm-box penalty: "no
throttle flag" ≠ cold). The receipt protocol for sustained sweeps is therefore **chunked**: the same v2 cells in
segments, cool-to-≤55°C gaps between segments, each segment's trace CLEAN, headline cells N≥5 on a
fresh serve. **First validated in full on 2026-07-25**: the 28-cell frontier receipt (chapter 2) ran
11/11 segments with zero throttle samples — the same cells both sustained attempts had failed —
with four deep segments passing 3–4°C from the line (recorded as WARNs, numbers valid).

gpt-oss-120b's full matrix stays parked behind the same cooling ceiling
([#6](https://github.com/maxspevack/spark-rocky/issues/6)); its single `tg128 (c1)` cell reproduced at
1.06× — recorded, but a single cell is below the parity bar.

Recipe mapping for any published entry: [`reproduce-pipeline.md`](reproduce-pipeline.md)
(`benchmarkId` → Firestore → recipe permalink). Board snapshot: `data/spark-arena-snapshot-2026-06-10.json`.
