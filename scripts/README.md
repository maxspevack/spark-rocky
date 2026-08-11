# scripts/ — build, package, install, verify

The mechanism behind deliverable #1. Full walkthrough + prerequisites: [`docs/build/build.md`](../docs/build/build.md). No-build path (flash, boot, check): [`docs/use/running.md`](../docs/use/running.md).

## Build pipeline (run in order — zero patches)

| Script | Produces |
|---|---|
| `01-build-kernel.sh` | the kernel selected by `KERNEL_SOURCE` (default **clk** = CIQ Linux Kernel @ `CLK_COMMIT`, its own aarch64 config, `-clk` uname lineage; `kernelorg` = stock tarball + the GB10 base config via `olddefconfig`), built **and packaged as the kernel rpm** in ONE `binrpm-pkg` invocation (#59), in `rockylinux:10`; writes the derived release + source stamps + `KRPM` to `build.env` |
| `02-build-rootfs.sh` | Rocky 10.2 rootfs — the kernel **dnf-installed from 01's rpm** (`rpm -q kernel` truthful in the image, fail-closed rpm-db verify), the MT7925 firmware as stock Rocky rpms (#64), and the minimal `CUDA_VER` toolkit (nvcc + cudart for the on-box CUDA proof) |
| `02b-install-gpu-docker.sh` | docker + the NVIDIA container toolkit in the rootfs, plus the **shipping open `.ko` packaged as `kmod-nvidia-open-<kver>` and dnf-installed** (#77 — sha256-gated `.run` source, boot auto-load config rides the rpm, depmod wired) |
| `02c-driver-userspace.sh` | pinned `DRIVER_VER` driver userspace via the sha256-gated `.run` (`--no-kernel-modules`), then **packaged as `nvidia-driver-userspace` from the install's ground-truth path-diff and dnf-installed over it** (#77 — every NVIDIA byte answers to `rpm -qf`) |
| `03-build-nvidia-open.sh` | **optional verify** — a standalone proof-build of the open kernel module in `rockylinux:10` (el10 gcc 14.3.1); `make all` skips it — the shipping `.ko` comes from `02b` |
| `04-build-image.sh` | the bootable image: `nvidia-drm.modeset=0` (compute-only GPU, EFI-fb console), root autologin at the console (behavior-gated in `validate.sh` §7; `root`/`rocky` stays the fallback credential — #97: the bake was always sound, the metal predated it), `mlx5_core` blacklist, masks `swap.target` + `systemd-firstboot`; bakes the one-command debug enabler (see the debug-hatch section of [`docs/build/build.md`](../docs/build/build.md)). Flash to USB is optional (`DEV=/dev/null` skips it). |

## Package · sign · write — the vendable release

| Script | Produces |
|---|---|
| `05-package-image.sh` | hardens for vending (strips builder keys, locks SSH to key-only, regenerates host identity, pre-builds the linker cache so first boot is fast) — **fail-closed**: re-verifies every step against the mounted image and aborts with **no checksum** on any failure; then compresses (`.raw.xz`) + emits a generated `BUILD-MANIFEST.txt` (hashes the resolved `config-$KVER`, not the base) + **vends the three rpms** (kernel #59, kmod + driver-userspace #77) with sha256 manifest lines |
| `serve-gate.sh` | the **pre-sign release gate** (#67): on the GB10, on the kernel being released, brings up the pinned vllm-node and proves a real vLLM serve — KV-cache allocation + the OpenAI API answering, the path `vectorAdd` never touches (the #65 class). Drops page caches in preflight (unified memory: `cudaMemGetInfo` sees `MemFree` — a prior image pull otherwise starves the startup check; hit live, #71). Fail-closed; a release is not signable until it prints `GATE-PASS` |
| `06-sign-release.sh` | GPG-clearsigns one `CHECKSUM` over the artifacts (Fedora model) + exports the public key — run on the box holding the release key (`OUTDIR=` points at the artifact dir) |
| `write-usb.sh` | writes the image to a USB and gates on **measured write throughput** (size-independent; refuses any non-removable disk) |
| `flash.sh` | the **end-user consumption path**: downloads the release (location from `config/release.env`), verifies the `CHECKSUM` signature against the **pinned key fingerprint** + the image sha, then writes through `write-usb.sh` — one command, fail-closed at every step |
| `07-verify-release.sh` | the **release-integrity gate** (#35), the **last release step**: fail-closed proof that **served == tag** — the served `BUILD-MANIFEST` commit, the signed `CHECKSUM`, the served image sha, **and each served rpm's sha** (#59/#77; manifests predating the rpms skip) all agree with the tag. HEAD past the tag is a loud warning, not a failure |

## Run on the booted box

| Script | Produces |
|---|---|
| `validate.sh` | the **box doctor** — one command proving the whole box came up as built: provenance (kernel/driver match the image), the stack (open driver + `nvidia-smi` + a real CUDA kernel) and runtime boot-hygiene (`modeset=0` active, mlx5 not loaded, swap off, dmesg clean) → one `PASS`/`FAIL` + the line to drop into an issue |
| `proof-of-life.sh` | OS + kernel + `nvidia-smi` + a CUDA `vectorAdd` on the GPU (validate.sh's CUDA check) |
| `install-baremetal.sh` | **DESTRUCTIVE** — wipes the NVMe, then rsyncs the running Rocky onto `/dev/nvme0n1p2` + grub. Run from the booted USB; a deliberate step separate from the non-destructive boot, and not yet clean-room-validated. |
| `upgrade-metal.sh` | **non-destructive in-place upgrade** of an existing install (#34) — dispatches on what differs vs the pins: a kernel bump **dnf-installs the kernel rpm** (#59) alongside and keeps the running kernel as a labeled GRUB fallback; both paths **dnf-install the kmod rpm** (#77); a driver bump adds the matched userspace + rebuilds the initramfs, rollback staged. Writes the metal provenance stamp. Prefer it for staying current |
| `run-benchmark-matrix.sh` | the **canonical full llama-benchy matrix** (deliverable #2) against a served model — the exact ~104-cell sweep behind the parity claim, encoded once so reproductions and regression-vs-self runs measure the same surface. **Auto-arms `templog`** for the run, so every benchmark is traced (a throttled run is caught post-hoc from that trace). Run after `spark-vllm-docker` is serving; full pipeline in [`docs/benchmark/reproduce-pipeline.md`](../docs/benchmark/reproduce-pipeline.md). |
| `templog.sh` | passive GPU/SoC thermal + memory sampler; auto-armed by `run-benchmark-matrix.sh` so every benchmark carries a forensic trace (logs only — throttles nothing). Shipped in the image. |
| `check-throttle.sh` | **post-hoc benchmark forensics** (#43): reads a `templog` trace and rules whether the GPU thermally throttled during the run — CLEAN / near-throttle WARN / THROTTLED (discard) / INDETERMINATE (cannot certify — never a false PASS). A throttled run's numbers never reach a median or a receipt |
| `receipt-chunked.sh` | the **chunked receipt protocol** for sustained sweeps (first validated in full 2026-07-25, the 28-cell frontier receipt): runs the official v2 cells in segments with cool-to-≤55°C gaps, per-segment `templog` + `check-throttle` verdicts, and resume-state clearing per segment — how a multi-hour sweep produces throttle-CLEAN numbers on a desk Spark. Protocol description: [`docs/benchmark/scoreboard.md`](../docs/benchmark/scoreboard.md) ch. 3; usage: [`docs/benchmark/reproduce-pipeline.md`](../docs/benchmark/reproduce-pipeline.md) |

## Stay current — release-engineering cadence (M4)

| Script | Produces |
|---|---|
| `drift-check.sh` | drift sensor (#24): per pin, `current` (`versions.env` + `serving-images.env`) vs `upstream` (**the `ciq-6.18.y` CLK branch tip — the trigger row since the clk default** / NVIDIA open-module releases; kernel.org + Rocky mirror as INFO rows; **the dgx-vllm mirror tag as the `SERVING` row** — INFO under 31 days, DRIFT past a month, #71) → MATCH/DRIFT, exit 2 on drift. The [`.github/workflows/drift-check.yml`](../.github/workflows/drift-check.yml) scheduled workflow runs it weekly + on-demand and opens a `pin-drift` tracking issue — the "when do we rebuild?" trigger. Detect-and-signal only; the bump itself is **manual by decision** (#26 closed 2026-06-29 — a human reads the drift issue, bumps the pin, rebuilds, and re-verifies). |

