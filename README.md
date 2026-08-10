# spark-rocky

Run the **NVIDIA DGX Spark (GB10)** on **Rocky Linux 10.2 + the CIQ Linux Kernel (CLK 6.18, `uname -r` → `6.18.42-clk`) + the open NVIDIA driver 610.57.04** — **zero patches carried by this repo** — and reproduce published [spark-arena.com](https://spark-arena.com) single-host benchmarks at parity (June receipts on the stock-mainline host, which stays one pin-flip away; **the CLK default is itself benchmark-validated at parity on the current pinned runtime** — median 1.010×, 2026-07-24).

*Soft-launched and unsupported: a personal-repo release, provided as-is. Not a CIQ product, and no support commitment.*

## Run it on your Spark (the fast path)

Clone, flash a USB, boot, run one check. Non-destructive — your NVMe is untouched:
```
git clone https://github.com/maxspevack/spark-rocky && cd spark-rocky
sudo scripts/flash.sh /dev/sdX     # 8 GB+ stick; find it with lsblk
```
Then boot the Spark from the USB and run `/root/validate.sh`. Full steps and the GUI alternative: [`docs/use/`](docs/use/).

## Three stories

- **[Use it](docs/use/)** — flash a USB, boot, validate, and install to the NVMe when you want it for real. The primary path.
- **[Build it](docs/build/)** — how this was made and how to rebuild from source: the kernel, the open module, the config-only delta. An OS-development project.
- **[Benchmark it](docs/benchmark/)** — the parity numbers, how to reproduce them, and how they compare to published results. Start at [`docs/benchmark/proof.md`](docs/benchmark/proof.md).

## The recipe registry

This repo is a [sparkrun](https://github.com/spark-arena/sparkrun) registry (#88): receipt-backed
GB10 serve recipes, consumable directly (resolution and mods verified from a clean consumer host,
#91; the serve semantics are what the receipts prove) —

```bash
scripts/install-sparkrun.sh                                    # pinned harness install (uv)
sparkrun registry add https://github.com/maxspevack/spark-rocky
sparkrun run @spark-rocky/<recipe> ...
```

The registry is the convenient **unpinned** channel — it tracks git HEAD and is covered by no
release signature; the [`receipts/`](receipts/) are the pinned one. Recipes serve what was proven
on their receipt date and carry no maintenance cadence against upstream drift. Tiers, promotion
rules, and the byte-binding ledgers: [`recipes/README.md`](recipes/README.md).

## What's proven

| Tier | Claim | State |
|---|---|---|
| Boots | Rocky 10.2 + CLK 6.18 on the GB10 — **6.18.42-clk**, 4k pages (the released Live USB, validated as a booted artifact before publishing); stock kernel.org 6.18.34/.35/.37/.38 equally proven | **PROVEN** |
| GPU + CUDA | the open driver builds and loads; the GPU computes | **PROVEN** |
| Bare metal | installed on the NVMe (reference box) | **PROVEN** — install is destructive, not yet clean-room-validated elsewhere |
| Benchmark | reproduce published single-host entries | **3 full-matrix parity** (35B-A3B-FP8 1.01×, 0.8B 0.96×, gemma-3-1b 1.05×; **re-confirmed on the current pinned runtime, 2026-07-24 — 0.8B median 1.010×**) **+ 2 frontier lanes receipt-grade on the current NVFP4+MTP meta** (Qwen3.6-35B: all 28 official cells throttle-CLEAN, statistically indistinguishable from the board's single-node field; Nemotron-3-Super-120B: statistical tie with board-best single-node, the cooling boundary measured per-cell). → [`docs/benchmark/scoreboard.md`](docs/benchmark/scoreboard.md) |
| Leaderboard | peer-reviewed, third-party-reproduced, then submitted | **harness validated** (the board's own sparkrun + official profile run here end-to-end, #72 → the sparkrun section of [`docs/benchmark/reproduce-pipeline.md`](docs/benchmark/reproduce-pipeline.md)); **first recipe contributed to the community registry** ([PR #12](https://github.com/spark-arena/community-recipe-registry/pull/12), Nemotron single-node, **merged 2026-08-04**; #75 closed); the experimental-tier recipe **merged 2026-08-07** ([recipe-registry#19](https://github.com/spark-arena/recipe-registry/pull/19)) — [live in the registry spark-arena.com serves](https://github.com/spark-arena/recipe-registry/blob/main/experimental-recipes/nemotron-3-super/nemotron-3-super-nvfp4-mtp-1x-vllm.yaml) (#82 closed, M5 complete); official arena-v2 profile run receipted 2026-08-10 (`receipts/arena-v2-*`) |

## Zero patches, and what's novel

Everything runs upstream and unmodified — no `.patch`/`.diff` exists anywhere in this repo. Kernel: the **CIQ Linux Kernel** ([CLK 6.18](https://github.com/ctrliq/kernel-src-tree), public GPL, commit-pinned; the `-clk` uname suffix states the lineage). Driver: NVIDIA's open module — not the novelty, since NVIDIA ships nothing else for this silicon. The novelty: **both CLK 6.18 and stock kernel.org 6.18 run the GB10 clean, at benchmark parity, making NVIDIA's vendored 6.17 kernel unnecessary.** Pins and the full accounting: [`THIRD_PARTY.md`](THIRD_PARTY.md). Pages are 4k, and that is a **trade, not a preference — 64k is the committed direction, held back by a driver defect**: 64k measured faster for concurrent serving, but 64k and the newest NVIDIA driver branches are mutually exclusive on this hardware — a defect we root-caused and reported upstream ([NVIDIA/open-gpu-kernel-modules#1269](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1269)). 64k works on the 580 LTSB branch (also what DGX OS ships) and faults on 590/595/610 — but 580 measured **10.4% slower** across a 104-cell matrix (2026-07-31), so buying 64k that way is a net loss and the 580 route is rejected on evidence. The direction is held by a **fail-closed gate, not an intention**: `DRIVER_64K_SAFE` in [`config/versions.env`](config/versions.env) lists the drivers proven correct under 64k, `05` refuses to package a 64k image on any other, and the shipping driver is deliberately not on the list — so when #1269 lands, the whole change is two reviewable lines. The full trade and evidence: [`docs/build/platform-deltas.md`](docs/build/platform-deltas.md#page-size--64k-is-the-destination-4k-is-what-ships-and-a-gate-holds-the-line-65-80-81).

## Repo layout

| Dir | Holds |
|---|---|
| [`docs/`](docs/) | the three stories: [use](docs/use/) · [build](docs/build/) · [benchmark](docs/benchmark/) |
| [`scripts/`](scripts/) | `flash`, `validate`, `install-baremetal`, and the `01`→`07` build/release pipeline |
| [`config/`](config/) | the kernel `.config` and the pin files — `versions.env` (build) + `serving-images.env` (benchmark stack) |
| [`recipes/`](recipes/) · [`data/`](data/) · [`receipts/`](receipts/) | the registry tiers + verbatim mirrors, the leaderboard snapshot, committed results |
| [`keys/`](keys/) | the release signing public key |

## License

MIT — see [LICENSE](LICENSE).
