# spark-rocky

Run the **NVIDIA DGX Spark (GB10)** on **Rocky Linux 10.2 + a stock upstream 6.18 kernel + the open NVIDIA driver 610.43.02** — **zero carried patches** — and reproduce published [spark-arena.com](https://spark-arena.com) single-host benchmarks at parity.

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
| Boots | Rocky 10.2 + stock 6.18 on the GB10 — **6.18.35**, 64k pages (the NVMe + the released Live USB) | **PROVEN** |
| GPU + CUDA | the open driver builds and loads; the GPU computes | **PROVEN** |
| Bare metal | installed on the NVMe (reference box) | **PROVEN** — install is destructive, not yet clean-room-validated elsewhere |
| Benchmark | reproduce published single-host entries | **5 reproduced** — 3 at full-matrix-median parity (35B-A3B-FP8 1.01×, 0.8B 0.96×, gemma-3-1b 1.05×); 2 single-cell. → [`docs/benchmark/scoreboard.md`](docs/benchmark/scoreboard.md) |
| Leaderboard | peer-reviewed, third-party-reproduced, then submitted | not started |

## Zero patches, and what's novel

Kernel: upstream + a `.config` (GB10 enablement — config, not code). Driver: the upstream open module, built in an el10 container. Benchmark stack: upstream, unmodified. No `.patch`/`.diff` exists anywhere in the repo. The open module is *mandatory* on the GB10 (NVIDIA ships only the open module for this silicon), so it is not the novelty. The novelty is that **it builds clean against stock kernel.org 6.18 (both 6.18.34 and 6.18.35), making NVIDIA's vendored 6.17 kernel unnecessary** — Rocky 10.2 + stock mainline + open module, a config-only delta, zero carried patches, and no public GB10 example doing this. Pins and the full accounting: [`docs/build/third-party.md`](docs/build/third-party.md). On top of that zero-patch base we make **one opinionated config choice — 64k pages** — a measurable win for the GB10's concurrent AI-serving workload (rationale, data, and the honest N=3 caveat: [`docs/build/platform-deltas.md`](docs/build/platform-deltas.md)).

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
