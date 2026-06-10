# spark-rocky

Run the **NVIDIA DGX Spark (GB10)** on **Rocky Linux 10.2 + a stock upstream kernel (6.18.34) + the open
NVIDIA driver (610.43.02)** — **zero carried patches** — and prove it against published spark-arena.com
benchmarks.

**This repo delivers two things:**

1. **A Live USB that jumpstarts the box.** Build it from `scripts/`, boot a DGX Spark off it to get the
   full Rocky + 6.18.34 + open-driver stack, then install to the internal NVMe with one script.
   → [`docs/build-and-install.md`](docs/build-and-install.md)
2. **A benchmark-reproduction mechanism.** Take any published single-host spark-arena.com entry, pull its
   exact recipe, serve it, and reproduce the numbers — from the bare-metal install **or** the USB.
   → [`docs/reproduce-pipeline.md`](docs/reproduce-pipeline.md)

**The claim:** on identical hardware running an identical AI-stack container, swapping the host to this RPM
stack reproduces the published single-host numbers at parity. *Reproduced, not "faster."*

## 1 · Live USB → running box

Build (on an aarch64 Rocky/Fedora box with Docker), in order:

```
scripts/01-build-kernel.sh         # 6.18.34 + GB10 .config, in a rockylinux:10 container — no patches
scripts/02-build-rootfs.sh         # Rocky 10.2 rootfs + the kernel
scripts/02b-install-gpu-docker.sh  # CUDA + container runtime
scripts/02c-driver-userspace.sh    # 610.43.02 driver userspace (.run, --no-kernel-modules)
scripts/03-build-nvidia-open.sh    # the open module, built in rockylinux:10 (el10 gcc 14.3.1)
scripts/04-build-image.sh          # assemble the bootable image; flash to USB
```

Boot the USB on the Spark (wired Ethernet), then install to the NVMe and verify:

```
scripts/install-baremetal.sh       # rsync the proven Rocky onto /dev/nvme0n1p2 + install grub
scripts/proof-of-life.sh           # OS + kernel + nvidia-smi + a CUDA vectorAdd on the GPU
```

Prerequisites, the exact sequence, and the first-install helper scripts:
[`docs/build-and-install.md`](docs/build-and-install.md).

## 2 · Reproduce a benchmark

Pick a single-host entry from [`docs/scoreboard.md`](docs/scoreboard.md) → pull its exact recipe → serve via
`spark-vllm-docker` → measure with `llama-benchy` → compare to the published matrix. Step-by-step, including
the leaderboard-entry→recipe mapping: [`docs/reproduce-pipeline.md`](docs/reproduce-pipeline.md). Committed
results: [`receipts/`](receipts/).

## Status

| Tier | Claim | State |
|---|---|---|
| 1 — Boots | Rocky 10.2 + 6.18.34 boots on the GB10 | **PROVEN** |
| 2 — GPU + CUDA | open driver builds/loads; GPU computes | **PROVEN** |
| 2.5 — Bare metal | installed on the NVMe; SSH + console | **PROVEN** |
| 3 — Benchmark | reproduce published single-host entries | **IN PROGRESS** — LFM2.5-350M `tg128(c1)`=246 vs 222.8 (+10.4%); Qwen3.5-35B-A3B-FP8 full 104-cell matrix reproduced, **median 1.01× = parity** |
| 4 — Leaderboard | peer-reviewed, third-party-reproduced; then Max submits | NOT STARTED |

## Zero patches — and what's actually novel

Kernel: upstream + a `.config` (GB10 enablement — config, not code). Driver: upstream open-modules, built in
an el10 container. Benchmark stack: upstream, unmodified. No `.patch`/`.diff` exists anywhere in the repo.
Pins + the reasoning: [`THIRD_PARTY.md`](THIRD_PARTY.md).

The open driver itself is **not** the novelty — on the GB10 it's mandatory (NVIDIA ships only the open kernel
module for this Blackwell-generation silicon, so `*-open` is the only path; everyone runs it). The novelty is
narrower and checkable:
**the open module builds clean against stock kernel.org mainline 6.18.34, so NVIDIA's vendored 6.17 kernel is
unnecessary.** We run Rocky 10.2 (RPM) + stock mainline + open module with a config-only delta and zero
carried patches — and a scan of the field turned up **no public GB10 example doing this** (other alt-distro
attempts run distro-patched or vendored-source kernels). As a bonus it sidesteps the recurring DGX-OS
"apt-upgrade-broke-my-driver" failure mode by construction.

## Repo layout

Every directory has its own README explaining what it holds and how to regenerate it.

| Dir | Holds | README |
|---|---|---|
| [`scripts/`](scripts/) | build the USB, install to NVMe, verify (deliverable #1) | [scripts/README](scripts/README.md) |
| [`recipes/`](recipes/) | serve configs, pulled verbatim from spark-arena | [recipes/README](recipes/README.md) |
| [`data/`](data/) | the leaderboard snapshot + published `/raw` matrices + `fetch.sh` to re-pull | [data/README](data/README.md) |
| [`receipts/`](receipts/) | committed raw results with full provenance — the proof | [receipts/README](receipts/README.md) |
| [`config/`](config/) | the kernel `.config` we build + the stock-DGX baseline | [config/README](config/README.md) |
| [`docs/`](docs/) | the explanation layer (build, reproduce, scoreboard, stack) | [docs/README](docs/README.md) |
| [`THIRD_PARTY.md`](THIRD_PARTY.md) | adopted upstreams, pins, and the zero-patch accounting | — |

## More

- [`docs/software-stack.md`](docs/software-stack.md) — the three environments (host / serving container /
  benchmark client) and why "PyTorch not found" is correct, not a gap.
- [`docs/stack-and-delta.md`](docs/stack-and-delta.md) — layer-by-layer: what we swapped vs held constant.

## License

MIT — see [LICENSE](LICENSE).
