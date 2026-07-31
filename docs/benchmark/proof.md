# A standard Rocky Linux stack on the CIQ Linux Kernel runs NVIDIA's DGX Spark – at single-host inference parity, and you can confirm it yourself

> Rocky 10.2 + the CIQ Linux Kernel (CLK 6.18, the shipped default — stock kernel.org 6.18 stays the always-live A/B knob, and the June parity receipts were recorded on it) + the open NVIDIA 610 driver, on the GB10, reproduces the community's own [spark-arena.com](https://spark-arena.com) single-host benchmarks. Every host change is auditable, the stack stays current through stock public tooling, and the published numbers came back.

## The proof

A full `llama-benchy` matrix sweeps the whole performance surface – **decode** (single-user generation), **prefill** (prompt processing), and **concurrency** (throughput as users stack up). No single cell is "the" number; the honest summary is the **median vs 1.0× (parity)**. Decode lands at or just above parity; prefill ran below it on the June runtime (~0.75–0.93× at the `pp2048` cell) — **re-measured 2026-07-24 on the current pinned runtime, that prefill deficit closes at the median (1.011× vs published): it was vLLM version drift, not the host** ([#18](https://github.com/maxspevack/spark-rocky/issues/18) tracks the one residual class — single-user contextual `pp2048 (c1)` cells, still 0.68–0.82×).

| Model | Scope | Measured | Full-matrix median vs published |
|---|---|---|:---:|
| Qwen3.5-35B-A3B-FP8 | full 104-cell matrix | 2026-06-10 | **1.01× – parity** |
| Qwen3.5-0.8B | full 104-cell matrix | 2026-06-10 | **0.96× – parity** |
| Qwen3.5-0.8B — current pinned runtime | full 104-cell matrix | **2026-07-24** | **1.010× – parity holds** |
| gemma-3-1b-it | full 56-cell matrix (context-capped) | 2026-06-10 | **1.05× – parity** |

Every row above is a dated measurement backed by a committed receipt in [`receipts/`](../../receipts/);
receipt filenames carry their measurement date. Numbers in this repo are never undated — if a figure
appears without one, treat it as a bug and check the receipt.

Medians spanning **0.96×–1.05×** straddle parity, the signature of a transparent host swap. Raw per-cell numbers and the prefill/decode breakdown are committed: [`receipts/`](../../receipts/) · [`scoreboard.md`](scoreboard.md).

**And the story continues on the current leaderboard meta.** On NVFP4 + MTP (Qwen3.6-35B-A3B, the
board's live headline lane), the same host runs **the board's own top recipe receipt-grade — zero
throttle samples across all 28 official cells — with results statistically indistinguishable from the
board's single-node field** (their entries: 102–119 `tg128 (c1)`; our two clean serves: means 100.1
and 118.3, overlapping ranges). The decomposition that got there is the parity thesis restated: the
resolvable movement was serving config (checkpoint format +48%, speculative depth +19%; the remaining
spread is run variance), never the host. **The flagship lane holds too:** Nemotron-3-Super-120B —
NVIDIA's largest single-Spark model — receipted at a statistical tie with the board-best single-node
entry (23.57 ± 1.74 at N=5 vs 23.71, measured 2026-07-25/26), with the MTP mechanism decomposed against a measured no-MTP
baseline and the box's cooling boundary measured per-cell. The receipts, the probe grids, and the
variance read: [`scoreboard.md`](scoreboard.md).

## We changed only the host

The benchmark runs in a serving container built from the spark-arena project's **own Dockerfile, unmodified** (vLLM + the model + the spark-arena recipe). We swapped only the **host beneath it** – Rocky 10.2 + an unmodified 6.18 kernel (stock kernel.org for the June receipts, the shipped CLK default for the 2026-07-24 gen-2 receipt — zero patches either way) + the open driver we built – and the host's `libcuda` is injected into that container at runtime. Same Dockerfile, same recipe, same GB10 silicon.

```mermaid
graph LR
    subgraph held["HELD CONSTANT — NVIDIA's, unmodified"]
        direction TB
        A["GB10 silicon"]
        B["GSP + platform firmware, via public LVFS<br/>(June receipts 610.43.02; current receipts 610.43.03)"]
        C["CUDA libraries +<br/>the open driver's source"]
        D["spark-arena Dockerfile<br/>+ vLLM + recipe + model"]
    end
    subgraph swapped["WE SWAPPED — ours, auditable, zero patches"]
        direction TB
        E["Rocky Linux 10.2 userspace"]
        F["unmodified 6.18 kernel — CLK default / stock A/B<br/>(4k pages; the 64k trade — #65)"]
        G["open module, built from<br/>NVIDIA's source, unmodified"]
    end
    swapped --> R["Published spark-arena<br/>numbers reproduced<br/>median 0.96–1.05x"]
    held --> R
```


One variable differed between the published runs and the June receipts: **the vLLM build, not the host** — spark-arena pins no runtime version, so entry and reproduction compiled vLLM on different dates. **Closed from our side on 2026-07-24:** the serving image is now pinned to a permanent dated [`spark-arena/dgx-vllm`](https://github.com/spark-arena/dgx-vllm) mirror tag ([`config/serving-images.env`](../../config/serving-images.env), #71), and the full 0.8B matrix on that current runtime lands **median 1.010× vs published — decode 1.010×, prefill 1.011×** (receipt `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt`). The parity claim survives the runtime catching up.

## What the host actually is

Everything swapped in is stock, current, and built from source — the exact coordinates:

| Layer | This stack |
|---|---|
| OS | Rocky Linux 10.2 |
| Kernel | CIQ Linux Kernel **6.18.39-clk**, **4k pages** (shipped 2026-07-23) — **CLK benchmark-validated at parity on the current runtime**: the `.39-clk` full-matrix receipt lands median 1.010× vs published, throttle-check CLEAN (`reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt`, #71/#61). *4k is a **measured trade, not a preference**: 64k faults on this driver branch — an NVIDIA DMA-submap misalignment we root-caused and filed ([open-driver #1269](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1269), spark-rocky [#65](https://github.com/maxspevack/spark-rocky/issues/65)) — and the only branch that is clean under 64k measured **10.4% slower** at identical page size (2026-07-31, receipt `reproduce-Qwen3.5-0.8B-driver-AB-580-vs-610-2026-07-31.txt`). Stock kernel.org stays one pin-flip away (`KERNEL_SOURCE=kernelorg`).* |
| Driver | open NVIDIA **610.43.03**, built from source unmodified (June parity receipts benched on 610.43.02; current receipts on 610.43.03) |
| CUDA | **13.0** |

**CUDA — the layer that actually moves inference numbers — is held identical to the stack the published entries ran on**, so the reproduced parity is a property of the OS/kernel/driver swap, not a CUDA artifact. Parity is not superiority.

## Why it holds up

- ✅ **Auditable.** Every host change is a named `.config` symbol or build step – no `.patch`/`.diff` anywhere in the repo, and the open driver is built unmodified (`make … SYSSRC=… modules`, no source edits). Nothing hidden to carry or rot.
- ✅ **Firmware-current, the standard way.** The box runs the latest platform firmware NVIDIA publishes to the **public LVFS**, applied with stock `fwupd` – no DGX OS, no entitlement, no proprietary tool. The parity result carries no stale-firmware confound.
- ✅ **Stays current with a one-line change.** Bump the kernel pin in [`config/versions.env`](../../config/versions.env) and rebuild — `CLK_COMMIT` tracks the `ciq-6.18.y` branch (the shipped default; the drift sensor fires when it moves), and the stock-mainline `KVER` pin stays live as the A/B knob. Either way a kernel refresh is a pin change, not a patch-rebase that rots — this repo carries zero patches against either tree.

→ **Reproduce or refute any entry yourself, credential-free:** [`reproduce-pipeline.md`](reproduce-pipeline.md)
