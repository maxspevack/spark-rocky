# Scoreboard — single-host, spark-arena vs spark-rocky

The claim this page carries, in one line: **on this host — Rocky 10.2 + the CIQ Linux Kernel + the open
610 driver, zero patches — published spark-arena numbers come back at parity, and on the current
leaderboard meta the same host measures receipt-grade results statistically indistinguishable from
the community's field. Every time a number moved, the mover was serving config, never the host.**

Three chapters, each with receipts.

## 1 — Parity: the host is invisible

Full-matrix medians vs published, `1.0× = parity` (June 2026 baseline; re-proven on the current
runtime 2026-07-24):

| model | scope | measured | published `tg128 c1` | ours | full-matrix median | receipt |
|---|---|---|---|---|---|---|
| Qwen3.5-35B-A3B-FP8 | 104-cell matrix | 2026-06-10 | 50.75 | 56.2 ±0.1 | **1.01× — parity** | `reproduce-Qwen3.5-35B-A3B-FP8-2026-06-10.txt` |
| Qwen3.5-0.8B | 104-cell matrix | 2026-06-10 | 121.2 | 123.0 ±0.2 | **0.96× — parity** | `reproduce-Qwen3.5-0.8B-2026-06-10.txt` |
| gemma-3-1b-it | 56-cell matrix (context-capped) | 2026-06-10 | 91.0 | 101.9 ±0.1 | **1.05× — parity** | `reproduce-gemma-3-1b-it-2026-06-10.txt` |
| Qwen3.5-0.8B — **current runtime, gen-2 pins** | 104-cell matrix on `6.18.39-clk` + the pinned dgx-vllm mirror (#71) | 2026-07-24 | 121.2 | 124.1 ±0.1 | **1.010× — parity holds** (decode 1.010×, prefill 1.011×), throttle-check CLEAN | `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt` |

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
the board's single-node vLLM field for this model: **102–119** `tg128 (c1)`, best entry 118.91
(committed comparison slice: `data/published-raw-frontier-tg128c1-2026-07-25.md`).

The first cut ran the official fp8-mtp recipe shape with the quant swapped to a compressed-tensors
NVFP4 checkpoint: **64 t/s**. A probe grid (single-cell `tg128(c1)@d0`, fresh serve per probe on the
pinned image, every probe throttle-CLEAN) decomposed the gap — and no axis was the host:

Probe grid measured **2026-07-25** (receipt `reproduce-Qwen3.6-35B-A3B-NVFP4-probes-2026-07-25.txt`):

| probe | config | `tg128(c1)@d0` | the move |
|---|---|---|---|
| control | `RedHatAI/` compressed-tensors NVFP4, official shape, nst=2 | 62.0 ±3.0 | baseline; thermal formally ruled out |
| format | **`nvidia/` ModelOpt NVFP4**, identical shape | 92.0 ±2.2 | **+48% — checkpoint format** |
| spec depth | + `num_speculative_tokens=3` | **109.1 ±4.8** | **+19% — speculative depth** |
| board lane | the board's own recipe: + marlin MoE, async-scheduling, triton draft | 118.3 ±8.0 | +8% point estimate — within run variance, not resolved (N=3 vs N=3); the raw runs (124.9/123.0) bracket board-best |

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

**Run variance is the honest headline at c1.** Two clean serves of the identical board config give
means of **100.1 (N=5) and 118.3 (N=3)** — single runs 90–125 — and the board's own single-node vLLM
field spans **102.35–118.91** (committed slice; every entry `cluster=1` — verified, and dual-node
entries run *lower*). Overlapping ranges with no resolvable separation: the board-best 118.91 and our
118.3 probe are the same phenomenon — a favorable serve of a high-variance config — not a
configuration gap. Statistically indistinguishable from the field, receipt-grade. Two config notes with teeth: the board recipe's
`max-num-seqs 4` deliberately caps the concurrency cells (our nst=3/default-MoE config measured
`d0 c10` at 384 t/s indicative vs 174 here — it is a single-user-lane specialist), and the published
v1 recipe does not run under sparkrun 0.2.40 as-is (`{{…}}` escaping; fixed in the 0.3.0-alpha line,
our default since 2026-07-27 — the committed variant is the syntax-only conversion, which runs on both).

### The flagship lane — Nemotron-3-Super-120B-A12B-NVFP4 ([#73](https://github.com/maxspevack/spark-rocky/issues/73))

NVIDIA's flagship-for-this-hardware, single node. Two findings and a measured boundary:

**The published lane was misread — the board-best already uses MTP.** The best single-node entry
(23.71 `tg128 (c1)`) reads as a no-MTP number; its own recipe runs `num_speculative_tokens=1`. The
true no-MTP baseline is the board's low mode (15.2–16.6), which our single-node conversion of the
dual-node community shape lands on directly: **16.48 ± 0.002** (run-to-run spread 0.004 t/s). MTP on/off is worth
**+41% at nst=1 and +56% at nst=3** against that baseline; the nst ordering (3 > 1 > 2) is indicated
at N=3 but adjacent gaps are not resolved. Receipt:
[`reproduce-Nemotron-3-Super-NVFP4-probes-2026-07-25.txt`](../../receipts/reproduce-Nemotron-3-Super-NVFP4-probes-2026-07-25.txt).

**At parity with board-best, receipt-grade** (measured 2026-07-25/26). On the board-best lineage upgraded to nst=3
([`recipes/spark-rocky/nemotron-3-super-120b-a12b-nvfp4-mtp-nst3-2026072302.yaml`](../../recipes/spark-rocky/nemotron-3-super-120b-a12b-nvfp4-mtp-nst3-2026072302.yaml) — promoted to the registry's official tier, #88),
the headline N=5 fresh-serve receipt is **23.57 ± 1.74, CLEAN** — statistically indistinguishable
from the 23.71 single-submission best. Probe serves on the same config reached a mean of 25.6 with
raw runs to 27.0, within noise of the sole *dual-node* entry (27.23). Not "faster"; at parity, with
receipts and the MTP mechanism decomposed.

**The cooling boundary, measured per-cell.** A 120B's cells each run minutes of sustained near-max
load: **14 of 28 official cells measure throttle-free on this box** (d0–d8192, plus d16384 c1–c2); of
the other 14, all but the five heaviest were re-attempted as single cells from cooled starts and
still throttled (the five heaviest stand on their chunked-segment values), reported
indicative-throttled with their traces
([`reproduce-Nemotron-3-Super-NVFP4-mtp-2026-07-26.txt`](../../receipts/reproduce-Nemotron-3-Super-NVFP4-mtp-2026-07-26.txt)).
That envelope is a property of this box's cooling under sustained load, not of the software stack —
the same stack measures the 35B clean across all 28 cells. The campaign also cost one silent hard hang
after ~10 cumulative hours at the thermal edge (no oops or panic; pstore empty; the journal
stops mid-write; required a physical power cycle) — the evidence, and the pattern it matches,
are tracked in [#62](https://github.com/maxspevack/spark-rocky/issues/62).

Full probe-grid + receipt record: #74 and #73. The queue behind them:
#75 closed — [community-recipe-registry#12](https://github.com/spark-arena/community-recipe-registry/pull/12)
**merged 2026-08-04**, the first upstream recipe contribution; its experimental-tier version
([recipe-registry#19](https://github.com/spark-arena/recipe-registry/pull/19)) **merged 2026-08-07**
— live in the registry spark-arena.com serves (#82 closed, M5 complete), [#76](https://github.com/maxspevack/spark-rocky/issues/76) (stretch).

## 3 — Discipline: why these numbers can be trusted

Every measured run on this box carries a 2-second thermal trace (`scripts/templog.sh`), and the
[#43](https://github.com/maxspevack/spark-rocky/issues/43) detector (`scripts/check-throttle.sh`)
issues a CLEAN/THROTTLED verdict post-hoc. **A THROTTLED run never becomes a receipt** — two full 35B
matrices have been discarded under this rule (both 2026-07-24 Pacific; receipts state UTC). The structural fact behind both:
**cooling saturation tracks the duration of sustained load, not the clock.** A ~55-minute continuous
sweep saturates — the deep×concurrent tail alone holds the GPU at 82–88°C for ~25 minutes with
headroom exhausted — while short bounded bursts ran CLEAN at every hour tested. The box runs indoors
at effectively constant ambient; time-of-day is not a variable in these results. The boundary scales
with per-cell load: a 35B's single cells all fit inside the envelope; a 120B's deepest cells
individually exceed it (the flagship receipt, chapter 2, measures that boundary per-cell).
In the one same-config comparison available, a clean-window cell inside a hot matrix read ~6% below a
fresh serve — direction consistent with residual heat, magnitude within single-serve variance ("no
throttle flag" ≠ cold). The receipt protocol for sustained sweeps is therefore **chunked**: the same v2 cells in
segments, cool-to-≤55°C gaps between segments, each segment's trace CLEAN, headline cells N≥5 on a
fresh serve. **First validated in full on 2026-07-25**: the 28-cell frontier receipt (chapter 2) ran
11/11 segments with zero throttle samples — the same cells both sustained attempts had failed —
with four deep segments passing 3–4°C from the line (recorded as WARNs, numbers valid).

**Two 2026-07-31 measurements, and the throttle gate earning its keep.** A driver-only A/B (580.173.02 vs
610.43.03, page size held at 4k, 104 cells each side, both legs throttle-CLEAN) put the 580 LTSB branch at
**0.896× — 10.4% slower**, 94/104 cells slower and none faster; that is what closed the "fall back to 580 to
get 64k" route (receipt
[`reproduce-Qwen3.5-0.8B-driver-AB-580-vs-610-2026-07-31.txt`](../../receipts/reproduce-Qwen3.5-0.8B-driver-AB-580-vs-610-2026-07-31.txt)).
A same-day page-size A/B produced one valid leg and one discard: **4k + `expandable_segments` measured
0.999× against the default allocator** (8 cells faster, 7 slower — the workaround is free), while the **64k
leg throttled** (4 slowdown samples, −2 °C headroom, 87 °C) and was **auto-discarded by the
[#43](https://github.com/maxspevack/spark-rocky/issues/43) gate** rather than reported. **There is no 64k
performance number on a correct stack yet** — the sustained-sweep ceiling described above is exactly why,
and the redo needs the chunked protocol. Tracked on
[#81](https://github.com/maxspevack/spark-rocky/issues/81).

gpt-oss-120b's full matrix stays parked behind the same cooling ceiling
([#6](https://github.com/maxspevack/spark-rocky/issues/6)); its single `tg128 (c1)` cell reproduced at
1.06× — recorded, but a single cell is below the parity bar.

Recipe mapping for any published entry: [`reproduce-pipeline.md`](reproduce-pipeline.md)
(`benchmarkId` → Firestore → recipe permalink). Board snapshot: `data/spark-arena-snapshot-2026-06-10.json`.
