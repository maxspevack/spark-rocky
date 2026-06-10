# scripts/ — build, install, verify

The mechanism behind deliverable #1. Full walkthrough + prerequisites: [`../docs/build-and-install.md`](../docs/build-and-install.md).

## Build pipeline (run in order — zero patches)

| Script | Produces |
|---|---|
| `01-build-kernel.sh` | upstream 6.18.34 + `config/rocky-6.18.34-gb10.config`, built in `rockylinux:10` |
| `02-build-rootfs.sh` | Rocky 10.2 rootfs with that kernel |
| `02b-install-gpu-docker.sh` | CUDA + container runtime in the rootfs |
| `02c-driver-userspace.sh` | 610.43.02 driver userspace (`.run --no-kernel-modules`) |
| `03-build-nvidia-open.sh` | the open kernel module, built in `rockylinux:10` (el10 gcc 14.3.1) |
| `04-build-image.sh` | the bootable image (flash to USB) |
| `install-baremetal.sh` | rsync the running Rocky onto `/dev/nvme0n1p2` + grub (run from the booted USB) |
| `proof-of-life.sh` | OS + kernel + `nvidia-smi` + a CUDA `vectorAdd` on the GPU |

## First-install helpers (NOT the clean pipeline)

One-time bring-up artifacts from this box's first install — kept for reference, not needed for a clean build:
`arm-boot.sh`, `prep-boot.sh`, `finalize-v2.sh`, `patch-stick-nvidia-fw.sh`, `ssh-ready.sh`,
`watch-rocky-v2.sh`, `rocky-nvbw.sh`, `cleanup-nvidia.sh`.

**Owed (tracked as an issue):** give `01`→`04` a single entry point (`make image`) and move these helpers to
`scripts/bringup/`. The `01`→`04` chain has not yet been re-run clean-room from a fresh checkout — that
reproduction is the pre-submission bar.
