# spark-rocky

Run the **NVIDIA DGX Spark (GB10)** on **Rocky Linux 10.2 + the CIQ Linux Kernel (CLK 6.18, `uname -r` → `6.18.42-clk`) + the open NVIDIA driver 610.57.04** — **zero source patches carried by this repo**, CI-enforced: the suite fails on any `.patch`/`.diff` in the tree or any script that applies one. Kernel = commit-pinned CLK source, driver = NVIDIA's sha256-pinned `.run`, userspace RPM = that `.run`'s payload repackaged byte-for-byte. What the stack *does* carry is **configuration** — kconfig deltas, boot parameters, module policy — every one named, classified, and reasoned in [`platform-deltas.md`](docs/build/platform-deltas.md). The pitch is auditability, not purity: you can read every divergence from stock, which no vendor image offers.

The proof grew in three steps. Published [spark-arena.com](https://spark-arena.com) single-host benchmarks reproduced **at parity** (June 2026; stock mainline stays one pin-flip away, and the CLK default re-validated at parity on the pinned runtime — median 1.010×, 2026-07-24). Then **receipt-grade statistical ties with board-best single-node entries** on the current NVFP4+MTP frontier — Nemotron-3-Super-120B (re-run under the board's official arena-v2 profile, 2026-08-10) and Qwen3.6-35B. And now the proven configs are directly consumable: this repo is a [sparkrun registry](#the-recipe-registry).

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
- **[Benchmark it](docs/benchmark/README.md)** — the numbers (parity and the frontier ties), how to reproduce them, how they compare to published results — and the fast path: skip reproduction and just run the proven configs from the registry.

## The recipe registry

This repo is a [sparkrun](https://github.com/spark-arena/sparkrun) registry: receipt-backed GB10 serve recipes, consumable directly (resolution and mods verified from a clean consumer host; the serve semantics are what the receipts prove) —

```bash
scripts/install-sparkrun.sh                                    # pinned harness install (uv)
sparkrun registry add https://github.com/maxspevack/spark-rocky
sparkrun run @spark-rocky/<recipe> ...
```

The registry is the convenient **unpinned** channel — it tracks git HEAD and is covered by no release signature; the [`receipts/`](receipts/) are the pinned one. Recipes serve what was proven on their receipt date and carry no maintenance cadence against upstream drift. Tiers, promotion rules, and the byte-binding ledgers: [`recipes/README.md`](recipes/README.md).

## What's proven

| Tier | Claim | State |
|---|---|---|
| Boots | Rocky 10.2 + CLK 6.18 on the GB10 — **6.18.42-clk**, 4k pages (the released Live USB, validated as a booted artifact before publishing); stock kernel.org 6.18.34/.35/.37/.38 equally proven | **PROVEN** |
| GPU + CUDA | the open driver builds and loads; the GPU computes | **PROVEN** |
| Bare metal | installed on the NVMe (reference box) | **PROVEN** — install is destructive, not yet clean-room-validated elsewhere |
| Benchmark | reproduce published single-host entries | **3 full-matrix parity** (35B-A3B-FP8 1.01×, 0.8B 0.96×, gemma-3-1b 1.05×; **re-confirmed on the current pinned runtime, 2026-07-24 — 0.8B median 1.010×**) **+ 2 frontier lanes receipt-grade on the current NVFP4+MTP meta** (Qwen3.6-35B: all 28 official cells throttle-CLEAN, statistically indistinguishable from the board's single-node field; Nemotron-3-Super-120B: statistical tie with board-best single-node, the cooling boundary measured per-cell). → [`docs/benchmark/scoreboard.md`](docs/benchmark/scoreboard.md) |
| Leaderboard | peer-reviewed, third-party-reproduced, then submitted | **harness validated** (the board's own sparkrun + official profile run here end-to-end, #72 → the sparkrun section of [`docs/benchmark/reproduce-pipeline.md`](docs/benchmark/reproduce-pipeline.md)); **first recipe contributed to the community registry** ([PR #12](https://github.com/spark-arena/community-recipe-registry/pull/12), Nemotron single-node, **merged 2026-08-04**; #75 closed); the experimental-tier recipe **merged 2026-08-07** ([recipe-registry#19](https://github.com/spark-arena/recipe-registry/pull/19)) — [live in the registry spark-arena.com serves](https://github.com/spark-arena/recipe-registry/blob/main/experimental-recipes/nemotron-3-super/nemotron-3-super-nvfp4-mtp-1x-vllm.yaml) (#82 closed, M5 complete); official arena-v2 profile run receipted 2026-08-10 (`receipts/arena-v2-*`) |

## Zero source patches, and what's novel

Every source tree runs upstream and unmodified — no `.patch`/`.diff` exists anywhere in this repo and no script applies one (re-verified 2026-08-10, now a CI invariant). The deltas this stack *does* carry are configuration and assembly, each one a ledger row with a decision and a reason: [`platform-deltas.md`](docs/build/platform-deltas.md). Kernel: the **CIQ Linux Kernel** ([CLK 6.18](https://github.com/ctrliq/kernel-src-tree), public GPL, commit-pinned; the `-clk` uname suffix states the lineage). Driver: NVIDIA's open module — not the novelty, since NVIDIA ships nothing else for this silicon. The novelty: **both CLK 6.18 and stock kernel.org 6.18 run the GB10 clean, at benchmark parity, making NVIDIA's vendored 6.17 kernel unnecessary.** Pins and the full accounting: [`THIRD_PARTY.md`](THIRD_PARTY.md). Pages are 4k, and that is a **trade, not a preference — 64k is the committed direction, held back by a driver defect**: 64k measured faster for concurrent serving, but 64k and the newest NVIDIA driver branches are mutually exclusive on this hardware — a defect we root-caused and reported upstream ([NVIDIA/open-gpu-kernel-modules#1269](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1269)). 64k works on the 580 LTSB branch (also what DGX OS ships) and faults on 590/595/610 — but 580 measured **10.4% slower** across a 104-cell matrix (2026-07-31), so buying 64k that way is a net loss and the 580 route is rejected on evidence. The direction is held by a **fail-closed gate, not an intention**: `DRIVER_64K_SAFE` in [`config/versions.env`](config/versions.env) lists the drivers proven correct under 64k, `05` refuses to package a 64k image on any other, and the shipping driver is deliberately not on the list — so when #1269 lands, the whole change is two reviewable lines. The full trade and evidence: [`docs/build/platform-deltas.md`](docs/build/platform-deltas.md#page-size--64k-is-the-destination-4k-is-what-ships-and-a-gate-holds-the-line-65-80-81).

## Repo layout

| Dir | Holds | Whose bytes |
|---|---|---|
| [`docs/`](docs/) | the three stories: [use](docs/use/) · [build](docs/build/) · [benchmark](docs/benchmark/) | ours |
| [`scripts/`](scripts/) | the numbered `01`→`07` build/release pipeline + the operational tools (`flash`, `validate`, `install-baremetal`, `drift-check`, …) | ours |
| [`config/`](config/) | the pins — `versions.env` (OS/kernel/driver) · `serving-images.env` (benchmark stack) — and the kernel `.config` | ours |
| [`recipes/`](recipes/) | the sparkrun registry tiers (served) + verbatim spark-arena mirrors (deliberately unserved) | tiers ours · mirrors theirs |
| [`receipts/`](receipts/) | measured results — the frozen evidence behind every claim above | ours |
| [`data/`](data/) | spark-arena's published data, pulled for comparison | theirs, frozen at pull |
| [`tests/`](tests/) | the invariant suite CI runs on every push (`make test`) | ours |
| [`keys/`](keys/) | the release signing public key | ours |

## License

MIT — see [LICENSE](LICENSE).
