# spark-rocky

Run the **NVIDIA DGX Spark (GB10)** on **Rocky Linux 10.2 + the CIQ Linux Kernel (CLK 6.18, `uname -r` → `6.18.39-clk`) + the open NVIDIA driver 610.43.03** — **zero patches carried by this repo** — and reproduce published [spark-arena.com](https://spark-arena.com) single-host benchmarks at parity (June receipts on the stock-mainline host, which stays one pin-flip away; **the CLK default is itself benchmark-validated at parity** — #61, 2026-07-23).

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

## What's proven

| Tier | Claim | State |
|---|---|---|
| Boots | Rocky 10.2 + CLK 6.18 on the GB10 — **6.18.39-clk**, 4k pages (the released Live USB); stock kernel.org 6.18.34/.35/.37/.38 equally proven | **PROVEN** |
| GPU + CUDA | the open driver builds and loads; the GPU computes | **PROVEN** |
| Bare metal | installed on the NVMe (reference box) | **PROVEN** — install is destructive, not yet clean-room-validated elsewhere |
| Benchmark | reproduce published single-host entries | **5 reproduced** — 3 at full-matrix-median parity (35B-A3B-FP8 1.01×, 0.8B 0.96×, gemma-3-1b 1.05×); 2 single-cell; **parity re-confirmed on the current pinned runtime, 2026-07-24 (0.8B median 1.010×)**. → [`docs/benchmark/scoreboard.md`](docs/benchmark/scoreboard.md) |
| Leaderboard | peer-reviewed, third-party-reproduced, then submitted | **harness validated** (the board's own sparkrun + official profile run here end-to-end, #72 → the sparkrun section of [`docs/benchmark/reproduce-pipeline.md`](docs/benchmark/reproduce-pipeline.md)); submission itself deliberately not started |

## Zero patches, and what's novel

Everything runs upstream and unmodified — no `.patch`/`.diff` exists anywhere in this repo. Kernel: the **CIQ Linux Kernel** ([CLK 6.18](https://github.com/ctrliq/kernel-src-tree), public GPL, commit-pinned; the `-clk` uname suffix states the lineage). Driver: NVIDIA's open module — not the novelty, since NVIDIA ships nothing else for this silicon. The novelty: **both CLK 6.18 and stock kernel.org 6.18 run the GB10 clean, at benchmark parity, making NVIDIA's vendored 6.17 kernel unnecessary.** Pins and the full accounting: [`THIRD_PARTY.md`](THIRD_PARTY.md). Pages are 4k: 64k measured faster for concurrent serving but faults large CUDA allocations ([#65](https://github.com/maxspevack/spark-rocky/issues/65)), so it was reverted — details in [`docs/build/platform-deltas.md`](docs/build/platform-deltas.md).

## Repo layout

| Dir | Holds |
|---|---|
| [`docs/`](docs/) | the three stories: [use](docs/use/) · [build](docs/build/) · [benchmark](docs/benchmark/) |
| [`scripts/`](scripts/) | `flash`, `validate`, `install-baremetal`, and the `01`→`07` build/release pipeline |
| [`config/`](config/) | the kernel `.config` and the pin files — `versions.env` (build) + `serving-images.env` (benchmark stack) |
| [`recipes/`](recipes/) · [`data/`](data/) · [`receipts/`](receipts/) | benchmark recipes, the leaderboard snapshot, committed results |
| [`keys/`](keys/) | the release signing public key |

## License

MIT — see [LICENSE](LICENSE).
