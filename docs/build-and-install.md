# Build the Live USB, install to the box, verify

Deliverable #1: a Live USB that jumpstarts a DGX Spark onto the zero-patch Rocky stack, then installs to the
internal NVMe. This doc is the canonical sequence. Everything here carries **zero source patches** — the only
inputs we author are a kernel `.config` and these scripts.

## Prerequisites (build host)

- An **aarch64** Linux host with **Docker** (the kernel and the open module are built in `rockylinux:10`
  containers, so the build host's own toolchain doesn't matter). A second DGX Spark, or any ARM box, works.
- The NVIDIA driver `.run` (610.43.02) for the userspace stage. Network access for Rocky packages + CUDA.
- ~40 GB free for the rootfs + image.

## Build pipeline (run in order)

| Step | Script | Produces | Patches |
|---|---|---|---|
| 1 | `01-build-kernel.sh` | upstream **6.18.34** built with `config/rocky-6.18.34-gb10.config`, in `rockylinux:10` | none |
| 2 | `02-build-rootfs.sh` | a Rocky **10.2** rootfs with that kernel installed | none |
| 2b | `02b-install-gpu-docker.sh` | CUDA stack + container runtime added to the rootfs | none |
| 2c | `02c-driver-userspace.sh` | driver **userspace** 610.43.02 (`.run --no-kernel-modules`) | none |
| 3 | `03-build-nvidia-open.sh` | the **open** kernel module, built in `rockylinux:10` (gcc 14.3.1 el10 — matches the kernel's compiler) | none |
| 4 | `04-build-image.sh` | a bootable Rocky 10.2 + 6.18.34 disk **image** | none |

> **The one non-obvious requirement (the headline finding):** build the open module in a `rockylinux:10`
> container, not on the host. The DGX-OS host's gcc-13 fails on `-fmin-function-alignment=8`; el10's gcc 14.3.1
> (the toolchain the kernel was built with) succeeds with zero source changes.

Flash the image from step 4 to a USB stick (`dd` / your tool of choice).

## Install to the box

1. Boot the Spark off the USB. Use **wired Ethernet** — the MT7925 WiFi firmware init is unreliable under
   6.18.34.
2. From the booted USB Rocky, run `install-baremetal.sh` — it rsyncs the proven Rocky onto `/dev/nvme0n1p2`
   and installs grub (arm64-efi, explicit `grub.cfg`, no BLS/shim/os-prober).
3. Reboot (USB removed) → the box comes up on the NVMe.

## Verify

`proof-of-life.sh` — confirms OS (Rocky 10.2), kernel (`uname -r`=6.18.34), `nvidia-smi` (GB10 / 610.43.02),
and compiles + runs a CUDA `vectorAdd` on the GPU. Green here = Tiers 1–2.5 reproduced.

## First-install helper scripts (NOT part of the clean pipeline)

These are operational artifacts from the first bring-up of *this* box — kept for reference, not part of the
reproducible build. A clean build does not need them:

- `arm-boot.sh`, `prep-boot.sh` — one-time DGX-grub boot into Rocky from the USB (first boot only).
- `finalize-v2.sh` — WiFi NM profile + re-arm one-time boot.
- `patch-stick-nvidia-fw.sh` — in-place stick patch (NVIDIA modules + GSP + WiFi fw) during iteration.
- `ssh-ready.sh` — make the booted stick SSH-reachable.
- `watch-rocky-v2.sh`, `rocky-nvbw.sh`, `cleanup-nvidia.sh` — observe/bandwidth/module-hygiene helpers.

**Cleanup owed (tracked):** these should move to `scripts/bringup/` or be cut, and the `01`→`04` pipeline
should get a single entry point (`make image`). See the repo issues.

## Honesty note (gafton)

The `01`→`04` chain was developed iteratively, not yet re-run clean-room from a fresh checkout to a booting
image. A **clean-room reproduction is the pre-submission bar** (and a tracked issue) — until then, "the repo
builds a Live USB" means "these scripts, in this order, built the running box," not "one command, verified
from scratch."
