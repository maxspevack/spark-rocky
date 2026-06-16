# Build the Live USB from source

How deliverable #1 is made, and how to rebuild it yourself. Everything carries **zero source patches** — the only inputs we author are a kernel `.config` and these scripts. To install the result on the NVMe, see [`../use/install.md`](../use/install.md); to package and sign a release, see [`release.md`](release.md).

## Prerequisites (build host)
- An **aarch64** Linux host with **Docker** — the kernel and the open module build in `rockylinux:10` containers, so the host toolchain doesn't matter. A second DGX Spark, or any ARM box, works.
- The NVIDIA driver `.run` (610.43.02) for the userspace stage. Network access for Rocky packages + CUDA.
- ~40 GB free for the rootfs + image.

## The pipeline (run in order)
All versions are pinned in one place, [`../../config/versions.env`](../../config/versions.env) (`KVER`, `DRIVER_VER`, `ROCKY_RELEASEVER`, and **`PAGE_SIZE`** — our opinionated `64k` page-size choice for the GB10 serving workload; see [platform-deltas](platform-deltas.md#page-size--the-opinionated-choice-64k)). Every script sources it; bumping a value and rebuilding is the whole "stay current" mechanism (below). `PAGE_SIZE` only flips `CONFIG_ARM64_64K_PAGES` in `01`; the kernel release stays plain `$KVER` (no `LOCALVERSION` suffix, so `uname -r` = `6.18.35`).

| Step | Script | Produces |
|---|---|---|
| 1 | `01-build-kernel.sh` | the pinned upstream kernel (`KVER`) built with the GB10 `.config`, in `rockylinux:10` |
| 2 | `02-build-rootfs.sh` | a current Rocky rootfs (`ROCKY_RELEASEVER`) with that kernel |
| 2b | `02b-install-gpu-docker.sh` | CUDA + container runtime + the open `.ko` (vermagic-checked == `KVER`) |
| 2c | `02c-driver-userspace.sh` | driver userspace `DRIVER_VER` (`.run --no-kernel-modules`) |
| 3 | `03-build-nvidia-open.sh` | the open kernel module, built in `rockylinux:10` (el10 gcc 14.3.1); asserts vermagic == `KVER` |
| 4 | `04-build-image.sh` | a bootable Rocky + `KVER` image (flashing to USB is optional; `05`/`06` package + sign it for release) |

> **The headline finding:** build the open module in a `rockylinux:10` container, not on the host. The DGX-OS host's gcc-13 fails on `-fmin-function-alignment=8`; el10's gcc 14.3.1 (the kernel's own toolchain) succeeds with zero source changes.

## Firmware — already current, via stock `fwupd` (no DGX OS, no entitlement)
The GB10's platform firmware (UEFI, EC, USB-C PD) is NVIDIA-published to the **public LVFS** and applied with stock `fwupd`, the same mechanism every `fwupd` Linux uses:
```
sudo fwupdmgr enable-remote lvfs
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr upgrade
```
As of 2026-06-11 the box reports the latest LVFS publishes (UEFI `0x0200980f`, EC `0x03000302`, USB-C PD `0x00000516`); the GPU VBIOS and GSP ride the driver. Benchmarks therefore run on the **same firmware a DGX OS box would** — no firmware confound. The per-delta analysis is in [`platform-deltas.md`](platform-deltas.md).

## Staying current
To pick up a new kernel (e.g. `6.18.35` → `6.18.36`) or Rocky updates:
1. Bump the version(s) in [`../../config/versions.env`](../../config/versions.env). One file; nothing else hardcodes a version. The base GB10 `.config` carries forward — `01`'s `olddefconfig` adapts it and prints the carried-vs-upstream symbol readout.
2. Rocky userspace updates come for free: `02` installs current packages at `ROCKY_RELEASEVER`.
3. Rebuild `01`→`04`. The open module is rebuilt against the new kernel — `02b`/`03` assert `vermagic == KVER` and fail otherwise.
4. Boot, then `proof-of-life.sh`: `uname -r` = the new `KVER`, `nvidia-smi`, the CUDA `vectorAdd`, and the wired NIC survives a warm reboot.
5. Re-run a benchmark and confirm parity. That is the upgrade validated — a stock-mainline kernel makes a bump a config change, not a patch-rebase.

## Validation status
The `01`→`04` chain was re-run clean-room on **2026-06-11**: it built a Live USB that boots the GB10 on the pinned stack, the open driver auto-loads, and the GPU computes (`proof-of-life` `vectorAdd` PASS), verified by booting off the USB and back **non-destructively**. That run found and fixed real bugs (module bloat, RHEL/Rocky `grub2-install`, a missing `depmod`/auto-load), all now in the scripts. **Honest edge:** `install-baremetal.sh` (the NVMe install) is not clean-room-validated — see [`../use/install.md`](../use/install.md).
