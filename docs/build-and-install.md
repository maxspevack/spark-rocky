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

All versions are pinned in one place — **[`config/versions.env`](../config/versions.env)** (`KVER`, `DRIVER_VER`,
`ROCKY_RELEASEVER`). Every script below sources it; bumping a value there and rebuilding is the whole
"stay current" mechanism (see *Upgrading* below). Stage the scripts + `config/` into the build workdir and run
from there; each script self-locates its workdir as the parent of `scripts/`.

| Step | Script | Produces | Patches |
|---|---|---|---|
| 1 | `01-build-kernel.sh` | the pinned upstream kernel (`KVER`) built with the GB10 `.config`, in `rockylinux:10` | none |
| 2 | `02-build-rootfs.sh` | a current Rocky rootfs (`ROCKY_RELEASEVER`) with that kernel installed | none |
| 2b | `02b-install-gpu-docker.sh` | CUDA stack + container runtime + open `.ko` (vermagic-checked == `KVER`) into the rootfs | none |
| 2c | `02c-driver-userspace.sh` | driver **userspace** `DRIVER_VER` (`.run --no-kernel-modules`) into the rootfs | none |
| 3 | `03-build-nvidia-open.sh` | the **open** kernel module, built in `rockylinux:10` (gcc 14.3.1 el10 — matches the kernel's compiler); the standalone proof, asserts vermagic == `KVER` | none |
| 4 | `04-build-image.sh` | a bootable Rocky + `KVER` disk **image**, then `dd` to a USB (guarded: refuses any non-removable target) | none |

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

`proof-of-life.sh` — confirms OS (Rocky), kernel (`uname -r` = the pinned `KVER`), `nvidia-smi` (GB10 /
`DRIVER_VER`), and compiles + runs a CUDA `vectorAdd` on the GPU. Green here = Tiers 1–2.5 reproduced.

## Upgrading / staying current

The stack pins three things, all in **[`config/versions.env`](../config/versions.env)**: the kernel (`KVER`),
the open driver (`DRIVER_VER`), and the Rocky userspace (`ROCKY_RELEASEVER`). To pick up a new upstream kernel
(e.g. `6.18.34` → `6.18.35`) or Rocky updates:

1. **Bump the version(s) in `config/versions.env`.** One file. Every script (`01`–`04`, `install-baremetal.sh`)
   sources it; nothing else hardcodes a version. The base GB10 `.config` carries forward across point releases —
   `01`'s `olddefconfig` adapts it to the new `KVER` and prints the carried-vs-upstream symbol readout.
2. **Pick up Rocky userspace updates** for free: the rootfs stage (`02`) installs current Rocky packages at
   `ROCKY_RELEASEVER`, so a rebuild pulls the latest; or `dnf update` on the running box.
3. **Rebuild `01`→`04`** (kernel → rootfs → driver → image). The open module **must** be rebuilt against the
   new kernel — `02b` and `03` assert its `vermagic` matches `KVER` exactly and fail the build otherwise.
4. **Boot, then `proof-of-life.sh`.** Confirm `uname -r` = the new `KVER`, `nvidia-smi` works, the CUDA
   `vectorAdd` runs, and (kernel-version-sensitive) the wired NIC survives a warm reboot.
5. **Re-run a benchmark** (e.g. Qwen3.5-35B-A3B-FP8) and confirm parity still holds. That is the upgrade
   validated — the whole point of pinning a *stock* upstream kernel is that bumping it is a config bump, not a
   patch-rebase.

## First-install helper scripts ([`scripts/bringup/`](../scripts/bringup/), NOT part of the clean pipeline)

Operational artifacts from the first bring-up of *this* box, moved to `scripts/bringup/`: kept for reference,
not part of the reproducible build. A clean build does not need them:

- `arm-boot.sh`, `prep-boot.sh` — one-time DGX-grub boot into Rocky from the USB (first boot only).
- `finalize-v2.sh` — WiFi NM profile + re-arm one-time boot.
- `patch-stick-nvidia-fw.sh` — in-place stick patch (NVIDIA modules + GSP + WiFi fw) during iteration.
- `ssh-ready.sh` — make the booted stick SSH-reachable.
- `watch-rocky-v2.sh`, `rocky-nvbw.sh`, `cleanup-nvidia.sh` — observe/bandwidth/module-hygiene helpers.

(A clean build invokes none of these.)

## Honesty note (gafton)

The `01`→`04` chain was developed iteratively, not yet re-run clean-room from a fresh checkout to a booting
image. Until then, "the repo builds a Live USB" means "these scripts, in this order, built the running box,"
not "one command, verified from scratch."
