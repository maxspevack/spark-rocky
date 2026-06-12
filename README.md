# spark-rocky

Run the **NVIDIA DGX Spark (GB10)** on **Rocky Linux 10.2 + a stock upstream **6.18** kernel + the open
NVIDIA driver (610.43.02)** — **zero carried patches** — and prove it against published spark-arena.com
benchmarks. (Exact kernel pinned in [`config/versions.env`](config/versions.env); benchmark receipts are on
6.18.34, and the build is validated on 6.18.35 — the version is a config bump, not load-bearing.)

**→ The 30-second version: [`PROOF.md`](PROOF.md)** — claim, parity table (5 models), and the three differentiators at a glance.

**This repo delivers two things:**

1. **A Live USB that jumpstarts the box.** Build it from `scripts/`, boot a DGX Spark off it to get the
   full Rocky + stock-6.18 + open-driver stack, then install to the internal NVMe with one script.
   → [`docs/build-and-install.md`](docs/build-and-install.md)
2. **A benchmark-reproduction mechanism.** Take any published single-host spark-arena.com entry, pull its
   exact recipe, serve it, and reproduce the numbers — from the bare-metal install **or** the USB.
   → [`docs/reproduce-pipeline.md`](docs/reproduce-pipeline.md)

**The claim:** on identical hardware running an identical AI-stack container, swapping the host to this RPM
stack reproduces the published single-host numbers at parity. *Reproduced, not "faster."*

## 1 · Live USB → running box

Build (on an aarch64 Rocky/Fedora box with Docker), in order:

```
scripts/01-build-kernel.sh         # stock 6.18 ($KVER from versions.env) + GB10 .config, in rockylinux:10 — no patches
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
| 1 — Boots | Rocky 10.2 + stock 6.18 boots on the GB10 (6.18.34 on NVMe, 6.18.35 off USB) | **PROVEN** |
| 2 — GPU + CUDA | open driver builds/loads; GPU computes | **PROVEN** |
| 2.5 — Bare metal | installed on the NVMe; SSH + console | **PROVEN** |
| 3 — Benchmark | reproduce published single-host entries | **5 reproduced** — 3 at **full-matrix-median parity** (Qwen3.5-35B-A3B-FP8 1.01×, Qwen3.5-0.8B 0.96×, gemma-3-1b-it 1.05×); 2 **single-cell** `tg128(c1)` (LFM2.5-350M +10.4%, gpt-oss-120b 1.06× — full matrix running). → [`docs/scoreboard.md`](docs/scoreboard.md) |
| 4 — Leaderboard | peer-reviewed, third-party-reproduced; then Max submits | NOT STARTED |

The Live USB was validated clean-room on 2026-06-11 — build → boot **6.18.35** off the USB → the open driver
**auto-loads** → `nvidia-smi` + a CUDA `vectorAdd` pass — proving the stack stands up on a newer kernel;
bumping it is a one-file [`config/versions.env`](config/versions.env) change. The box also runs **NVIDIA's
latest platform firmware via stock public `fwupd`/LVFS** (no DGX OS, no entitlement), so benchmarks run on the
same firmware a DGX OS box would — details in [`docs/build-and-install.md`](docs/build-and-install.md).

## Zero patches — and what's actually novel

Kernel: upstream + a `.config` (GB10 enablement — config, not code). Driver: upstream open-modules, built in
an el10 container. Benchmark stack: upstream, unmodified. No `.patch`/`.diff` exists anywhere in the repo.
Pins + the reasoning: [`THIRD_PARTY.md`](THIRD_PARTY.md).

The open driver itself is **not** the novelty — on the GB10 it's mandatory (NVIDIA ships only the open kernel
module for this Blackwell-generation silicon, so `*-open` is the only path; everyone runs it). The novelty is
narrower and checkable:
**the open module builds clean against stock kernel.org mainline 6.18 (validated on both 6.18.34 and 6.18.35),
so NVIDIA's vendored 6.17 kernel is unnecessary.** We run Rocky 10.2 (RPM) + stock mainline + open module with a config-only delta and zero
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
| [`docs/`](docs/) | the explanation layer (build, reproduce, scoreboard, software-stack, platform-deltas) | [docs/README](docs/README.md) |
| [`THIRD_PARTY.md`](THIRD_PARTY.md) | adopted upstreams, pins, and the zero-patch accounting | — |

## More

- [`docs/software-stack.md`](docs/software-stack.md) — the full stack, the layer-by-layer delta vs DGX OS,
  "PyTorch not found" explained, and the controlled-experiment argument.
- [`docs/platform-deltas.md`](docs/platform-deltas.md) — every boot-time delta classified (carry / upstream /
  decline / benign), and the firmware-currency conclusion.
- [`docs/verify.md`](docs/verify.md) — releases are GPG-clearsigned; import the key, `gpg --verify CHECKSUM`,
  `sha256sum -c`, then write. The signing-key fingerprint lives there and in [`keys/`](keys/).

## License

MIT — see [LICENSE](LICENSE).
