# spark-rocky

Run the **NVIDIA DGX Spark (GB10)** on **Rocky Linux 10.2 + the CIQ Linux Kernel (CLK 6.18, `uname -r` → `6.18.38-clk`) + the open NVIDIA driver 610.43.03** — **zero patches carried by this repo** — and reproduce published [spark-arena.com](https://spark-arena.com) single-host benchmarks at parity (receipts recorded on the stock-mainline host, which stays one pin-flip away).

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
| Boots | Rocky 10.2 + CLK 6.18 on the GB10 — **6.18.38-clk**, 4k pages (the NVMe + the released Live USB); stock kernel.org 6.18.34–6.18.38 equally proven | **PROVEN** |
| GPU + CUDA | the open driver builds and loads; the GPU computes | **PROVEN** |
| Bare metal | installed on the NVMe (reference box) | **PROVEN** — install is destructive, not yet clean-room-validated elsewhere |
| Benchmark | reproduce published single-host entries | **5 reproduced** — 3 at full-matrix-median parity (35B-A3B-FP8 1.01×, 0.8B 0.96×, gemma-3-1b 1.05×); 2 single-cell. → [`docs/benchmark/scoreboard.md`](docs/benchmark/scoreboard.md) |
| Leaderboard | peer-reviewed, third-party-reproduced, then submitted | not started |

## Zero patches, and what's novel

Kernel: the **CIQ Linux Kernel** — CLK 6.18, the public GPL tree at [`ctrliq/kernel-src-tree`](https://github.com/ctrliq/kernel-src-tree), commit-pinned, built unmodified with its own aarch64 config (the `-clk` uname suffix states the lineage) — GB10-validated end-to-end 2026-07-17 (boot, open driver, CUDA, 8 GiB managed memory). Driver: the upstream open module, built in an el10 container. Benchmark stack: upstream, unmodified. No `.patch`/`.diff` exists anywhere in this repo. The open module is *mandatory* on the GB10 (NVIDIA ships only the open module for this silicon), so it is not the novelty. The novelty is that **both CLK 6.18 and stock kernel.org 6.18 (6.18.34 through 6.18.38) run the GB10 clean, making NVIDIA's vendored 6.17 kernel unnecessary** — the stock path remains the A/B knob (`KERNEL_SOURCE=kernelorg`, one pin-flip) and is where the parity receipts were recorded. Pins and the full accounting: [`docs/build/third-party.md`](docs/build/third-party.md). We ran **64k pages** as an opinionated tuning choice (a measured concurrent-serving win in June), but **reverted to 4k on 2026-07-17**: large CUDA allocations fault under 64k — a GPU Xid 31 MMU fault in the ~90 GB KV-cache path ([#65](https://github.com/maxspevack/spark-rocky/issues/65)) — and 4k is unaffected. Controlled reverts exonerated the kernel, driver, and firmware (the exact June stack, restored, still faults), so this is a CUDA-level fault, not a kernel regression; the root-cause hunt is deferred ([#68](https://github.com/maxspevack/spark-rocky/issues/68)) and 4k is the resolution. Details: [`docs/build/platform-deltas.md`](docs/build/platform-deltas.md).

## Repo layout

| Dir | Holds |
|---|---|
| [`docs/`](docs/) | the three stories: [use](docs/use/) · [build](docs/build/) · [benchmark](docs/benchmark/) |
| [`scripts/`](scripts/) | `flash`, `validate`, `install-baremetal`, and the `01`→`07` build/release pipeline |
| [`config/`](config/) | the kernel `.config` and the pinned `versions.env` |
| [`recipes/`](recipes/) · [`data/`](data/) · [`receipts/`](receipts/) | benchmark recipes, the leaderboard snapshot, committed results |
| [`keys/`](keys/) | the release signing public key |

## License

MIT — see [LICENSE](LICENSE).
