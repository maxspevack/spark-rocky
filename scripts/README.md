# scripts/ — build, package, install, verify

The mechanism behind deliverable #1. Full walkthrough + prerequisites: [`../docs/build-and-install.md`](../docs/build-and-install.md). No-build path (write the signed image): [`../docs/write-to-usb.md`](../docs/write-to-usb.md).

## Build pipeline (run in order — zero patches)

| Script | Produces |
|---|---|
| `01-build-kernel.sh` | stock upstream `$KVER` (from `versions.env`; currently 6.18.35) + `config/rocky-6.18.34-gb10.config` (base config — carries forward to newer `$KVER` via `olddefconfig`; the resolved `config-$KVER` is what the manifest hashes), built in `rockylinux:10` |
| `02-build-rootfs.sh` | Rocky 10.2 rootfs with that kernel |
| `02b-install-gpu-docker.sh` | CUDA + container runtime in the rootfs |
| `02c-driver-userspace.sh` | 610.43.02 driver userspace (`.run --no-kernel-modules`) |
| `03-build-nvidia-open.sh` | the open kernel module, built in `rockylinux:10` (el10 gcc 14.3.1) |
| `04-build-image.sh` | the bootable image: `nvidia-drm.modeset=0` (compute-only GPU, EFI-fb console), autologin, `mlx5_core` blacklist, masks `swap.target` + `systemd-firstboot`; bakes the one-command debug enabler (see [`../docs/debug-hatch.md`](../docs/debug-hatch.md)). Flash to USB is optional (`DEV=/dev/null` skips it). |

## Package · sign · write — the vendable release

| Script | Produces |
|---|---|
| `05-package-image.sh` | hardens for vending (strips builder keys, locks SSH to key-only, regenerates host identity, pre-builds the linker cache so first boot is fast) — **fail-closed**: re-verifies every step against the mounted image and aborts with **no checksum** on any failure; then compresses (`.raw.xz`) + emits a generated `BUILD-MANIFEST.txt` (hashes the resolved `config-$KVER`, not the base) |
| `06-sign-release.sh` | GPG-clearsigns one `CHECKSUM` over the artifacts (Fedora model) + exports the public key — run on the box holding the release key (`OUTDIR=` points at the artifact dir) |
| `write-usb.sh` | writes the image to a USB and gates on **measured write throughput** (size-independent; refuses any non-removable disk) |

## Run on the booted box

| Script | Produces |
|---|---|
| `validate.sh` | one command: kernel + open driver + `nvidia-smi` + a **real CUDA kernel** → `PASS`/`FAIL` + the line to drop into a new issue |
| `proof-of-life.sh` | OS + kernel + `nvidia-smi` + a CUDA `vectorAdd` on the GPU (validate.sh's CUDA check) |
| `install-baremetal.sh` | **DESTRUCTIVE** — wipes the NVMe, then rsyncs the running Rocky onto `/dev/nvme0n1p2` + grub. Run from the booted USB; a deliberate step separate from the non-destructive boot, and not yet clean-room-validated. |

## First-install helpers — [`bringup/`](bringup/)

One-time bring-up artifacts from this box's first install, moved to [`scripts/bringup/`](bringup/):
`arm-boot.sh`, `prep-boot.sh`, `finalize-v2.sh`, `patch-stick-nvidia-fw.sh`, `ssh-ready.sh`,
`watch-rocky-v2.sh`, `rocky-nvbw.sh`, `cleanup-nvidia.sh`. Plus `templog.sh` (GPU/SoC temperature logging
during benchmark runs). A clean build uses only the pipelines above; these are kept for reference.
