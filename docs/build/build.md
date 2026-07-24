# Build the Live USB from source

How deliverable #1 is made, and how to rebuild it yourself. Everything carries **zero source patches** — the only inputs we author are a kernel `.config` and these scripts. To install the result on the NVMe, see [`../use/install.md`](../use/install.md); to package and sign a release, see [`release.md`](release.md).

## Prerequisites (build host)
- An **aarch64** Linux host with **Docker** — the kernel and the open module build in `rockylinux:10` containers, so the host toolchain doesn't matter. A second DGX Spark, or any ARM box, works.
- The NVIDIA driver `.run` (the `DRIVER_VER` pinned in `versions.env`, verified against `DRIVER_SHA256`) for the userspace stage. Network access for Rocky packages + CUDA.
- ~40 GB free for the rootfs + image.

## The pipeline (run in order)
All versions are pinned in one place, [`../../config/versions.env`](../../config/versions.env) (`KERNEL_SOURCE` — **`clk` is the default**, `CLK_COMMIT`, the `kernelorg` A/B pins `KVER`/`KCONFIG`/`KERNEL_SHA256`, `DRIVER_VER`+`DRIVER_SHA256`, `ROCKY_RELEASEVER`, and **`PAGE_SIZE`** — currently `4k`; 64k was an opinionated serving-tuning choice, reverted 2026-07-17 pending a 64k-only kernel serve regression, see [platform-deltas](platform-deltas.md#page-size--currently-4k-64k-reverted-65)). Every script sources it; bumping a pin and rebuilding is the whole "stay current" mechanism (below). The kernel release is derived by `make kernelrelease`: clk builds carry the **`-clk` lineage suffix** (`uname -r` = `6.18.38-clk` — uname states *where the source came from*, the distro convention), while `PAGE_SIZE` only flips the `CONFIG_ARM64_4K_PAGES`/`_64K_PAGES` symbol (config properties never ride uname). Integrity models differ honestly per source: kernel.org tarballs verify against a GPG-signed SHA256 pin; the CLK tarball is commit-addressed over TLS (GitHub archive bytes are not byte-stable, so no tarball hash exists to pin).

| Step | Script | Produces |
|---|---|---|
| 1 | `01-build-kernel.sh` | the pinned upstream kernel (`KVER`) built with the GB10 `.config`, in `rockylinux:10` — **plus a kernel RPM** (`binrpm-pkg`, stripped; see *The kernel is an RPM* below) |
| 2 | `02-build-rootfs.sh` | a current Rocky rootfs (`ROCKY_RELEASEVER`) with that kernel, **dnf-installed from 01's RPM** |
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

## Boot-chain posture (Secure Boot: unsupported by design)
The kernels this pipeline produces are **unsigned**, and `01` deliberately neutralizes the in-kernel
signing machinery on both source paths (`MODULE_SIG`, `MODULE_SIG_ALL`, `SYSTEM_TRUSTED_KEYS`,
`SECURITY_LOCKDOWN_LSM`): with the distro key paths active, a tarball build auto-generates an
*ephemeral* signing key and embeds its certificate in the kernel Image — nondeterministic bytes that
break build reproducibility — while the out-of-tree open NVIDIA module would stay unsigned regardless.
Consequences, stated plainly: **Secure Boot must be disabled on the box** (the validation Spark reports
`SecureBoot disabled`, setup mode); the release's trust anchor is the **GPG-signed artifact**
([`verify.md`](../use/verify.md)) — provenance of the bytes, not power-on boot-chain attestation.
If a signed-boot requirement ever materializes, the path is a MOK-enrolled signing key + signed kernel
and modules — a deliberate future project, not a pin-flip; nothing in the current pipeline pretends
otherwise.

## The kernel is an RPM (#59)

`01` finishes by packaging the built kernel with the kernel's own `make INSTALL_MOD_STRIP=1 binrpm-pkg`
(stripped is mandatory — unstripped modules balloon the rpm ~61M → ~1.5G), and everything downstream
installs the kernel **from that rpm, via dnf** — `02` into the image rootfs (`--installroot`),
`upgrade-metal.sh` onto the metal. What that buys:

- **A truthful package database.** `rpm -q kernel` on the booted box names the exact kernel running —
  no more file-copied kernels invisible to rpm. The doctor (`validate.sh`) checks it; `05` refuses to
  package an image whose rpm database doesn't know its kernel, and stamps the NEVRA into
  `/etc/spark-rocky-release` and the build manifest.
- **NEVRA provenance.** The rpm is named by the kernel's own mkspec: `kernel-6.18.38_clk-2.aarch64` —
  rpm forbids dashes in `Version`, so the `-clk` lineage suffix sanitizes to `_clk` **in the NEVRA
  only**; module paths, `/boot` file names, and `uname -r` all keep the true `6.18.38-clk`.
- **dnf-native rollback semantics on the metal**, alongside the GRUB fallback entry.

Two deliberate boundaries: the rpm's `%post` (`kernel-install`/BLS registration) is **skipped**
(`tsflags=noscripts`) because this image owns its boot plumbing — a static GRUB config and our dracut
initramfs, both built in `04` — and the scripts replicate the `%post` file copies
(`vmlinuz`/`System.map`/`config` → `/boot`) deterministically instead. And the rpm carries only the
kernel's own modules: the open NVIDIA `.ko` set (`03`) stays a separate tree in
`/lib/modules/$KVER/extra/`, re-carried explicitly on a metal kernel bump (fail-closed `modules.dep`
check backstops it). The `kernel-headers`/`kernel-devel` subpackages are built but not shipped — the
open module builds against the kernel *tree*, not the rpm, and that decoupling is deliberate.

## Staying current
The refresh trigger is **CLK, not kernel.org** (the clk default, 2026-07-17): the drift sensor fires when
the `ciq-6.18.y` branch moves past the pinned `CLK_COMMIT`; kernel.org is reported as context (the
`kernelorg` A/B pin). To pick up a new kernel or Rocky updates:
1. Bump the pin in [`../../config/versions.env`](../../config/versions.env) — `CLK_COMMIT` for the shipped
   kernel (read the branch delta first; the pin bump is a reviewable diff), or `KVER`+`KERNEL_SHA256` for
   the kernelorg A/B path. One file; nothing else hardcodes a version.
2. Rocky userspace updates come for free: `02` installs current packages at `ROCKY_RELEASEVER`.
3. Rebuild `01`→`04`. The kernel release is derived (`make kernelrelease` — clk builds carry the `-clk`
   lineage suffix) and propagates via `build.env`; the open module is rebuilt against the new tree —
   `02b`/`03` assert `vermagic == KVER` and fail otherwise.
4. Boot, then `proof-of-life.sh`: `uname -r` = the new release (e.g. `6.18.38-clk`), `nvidia-smi`, the CUDA
   `vectorAdd`, and the wired NIC survives a warm reboot.
5. Re-run a benchmark and confirm parity. That is the upgrade validated — a pinned-tree kernel makes a bump
   a config change, not a patch-rebase (this repo carries zero patches against either tree).

## Validation status
The `01`→`04` chain was re-run clean-room on **2026-06-11**: it built a Live USB that boots the GB10 on the pinned stack, the open driver auto-loads, and the GPU computes (`proof-of-life` `vectorAdd` PASS), verified by booting off the USB and back **non-destructively**. That run found and fixed real bugs (module bloat, RHEL/Rocky `grub2-install`, a missing `depmod`/auto-load), all now in the scripts. **Honest edge:** `install-baremetal.sh` (the NVMe install) is not clean-room-validated — see [`../use/install.md`](../use/install.md).
