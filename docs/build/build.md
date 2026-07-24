# Build the Live USB from source

How deliverable #1 is made, and how to rebuild it yourself. Everything carries **zero source patches** — the only inputs we author are a kernel `.config` and these scripts. To install the result on the NVMe, see [`../use/install.md`](../use/install.md); to package and sign a release, see [`release.md`](release.md).

## Prerequisites (build host)
- An **aarch64** Linux host with **Docker** — the kernel and the open module build in `rockylinux:10` containers, so the host toolchain doesn't matter. A second DGX Spark, or any ARM box, works.
- The NVIDIA driver `.run` (the `DRIVER_VER` pinned in `versions.env`) — **fetched automatically by `02b` if absent**, verified fail-closed against `DRIVER_SHA256`. Network access for Rocky packages + CUDA.
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
The current firmware set and its history live in **one place**, [`platform-deltas.md`](platform-deltas.md)
(UEFI `0x02009b0b` + EC `0x03000508` as of 2026-07-17); the GPU VBIOS and GSP ride the driver. Benchmarks
therefore run on the **same firmware a DGX OS box would** — no firmware confound.

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
- **A served, attested artifact — since `spark-rocky-live-20260723`.** The kernel rpm (and the #77
  kmod + userspace rpms) are vended by `05` next to the image, uploaded to the release bucket, and
  covered by `06`'s **clearsigned CHECKSUM** — the same detached-GPG trust model as the image (basic
  attestation by design: the rpms carry no embedded signature; the signed CHECKSUM is the trust
  anchor, `07-verify` binds each served rpm ↔ manifest ↔ signature fail-closed). A downstream can
  consume just the kernel — `dnf install` the rpm on any GB10 Rocky host — without flashing the image.

Two deliberate boundaries: the rpm's `%post` (`kernel-install`/BLS registration) is **skipped**
(`tsflags=noscripts`) because this image owns its boot plumbing — a static GRUB config and our dracut
initramfs, both built in `04` — and the scripts replicate the `%post` file copies
(`vmlinuz`/`System.map`/`config` → `/boot`) deterministically instead. And the rpm carries only the
kernel's own modules: the open NVIDIA `.ko` set (`03`) stays a separate tree in
`/lib/modules/$KVER/extra/`, re-carried explicitly on a metal kernel bump (fail-closed `modules.dep`
check backstops it). The `kernel-headers`/`kernel-devel` subpackages are built but not shipped — the
open module builds against the kernel *tree*, not the rpm, and that decoupling is deliberate.

### The RPM accounting — every byte on the box, named

The goal (stated 2026-07-23): **represent the entire box through RPMs** — upstream Rocky packages or
packages this pipeline builds. Current state, precisely:

**RPMs this pipeline builds:**

| Package | Built by | Shipped? | Where it goes |
|---|---|---|---|
| `kernel-<KVER-sanitized>-N.aarch64` | `01` (`binrpm-pkg`) | **yes** | dnf-installed into the image (`02`) and onto the metal (`upgrade-metal.sh`); vended + served next to the image, covered by the signed CHECKSUM |
| `kmod-nvidia-open-<KVER-sanitized>-<driver>.aarch64` (#77) | `02b` | **yes** | the open `.ko` set + the boot auto-load config; kver rides the **Name** (kernel-package-style side-by-side coexistence), `Requires: kernel = <kver>`; dnf-installed into the image and onto the metal on both `upgrade-metal` paths |
| `nvidia-driver-userspace-<driver>.aarch64` (#77) | `02c` | **yes** | the `.run` payload — libraries, tools, **GSP firmware** — packaged from the ground-truth path-diff of the actual install (the manifest regenerates per driver bump); dnf-installed over the laid files |
| `kernel-headers-…` / `kernel-devel-…` | `01` | no | built as a side effect; the open module builds against the tree — deliberate decoupling |

**RPMs from package repos** (all `gpgcheck=1`):

| Set | Repo | What |
|---|---|---|
| Rocky 10.2 BaseOS + AppStream | Rocky | the entire userspace of the image |
| `cuda-nvcc-*`, `cuda-cudart-*` (the `CUDA_VER` pin) | NVIDIA CUDA el10 | minimal CUDA for the on-box doctor |
| `docker-ce`, `nvidia-container-toolkit` | Docker / NVIDIA | the serving container runtime |
| `mt7xxx-firmware`, `wireless-regdb` (#64) | Rocky | MT7925 WiFi/BT blobs + regulatory.db — rpm-owned, kernel decompresses the `.xz`/`.zst` blobs at load time |

**NOT rpm-managed** (the deliberate remainder):

| Thing | How it lands | Why it stays out |
|---|---|---|
| dracut initramfs + static `grub.cfg` | generated by `04` per image | machine-specific generated output, not distributable content |
| the ops scripts (`validate.sh`, `templog.sh`, …) | baked by `04`/`05` | could ride a tiny noarch rpm; low value while the image is the unit of distribution |

`rpm -qa` on the booted box plus this table accounts for every byte. Since #77 (2026-07-23), **every
NVIDIA byte — kernel modules, userspace, GSP firmware — answers to `rpm -qf`**; the doctor checks all
three packages on the booted box.

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
Two validation anchors, honestly dated: the `01`→`04` chain was re-run **clean-room on 2026-06-11**
(a Live USB that boots the GB10, driver auto-loads, `vectorAdd` PASS, non-destructive USB-and-back) —
that run predates the CLK default and the rpm pipeline. The **rpm pipeline was validated 2026-07-23**,
not clean-room but end-to-end on the reference box: full `01`→`04` build at HEAD, metal upgraded via
the dnf/rpm path (`6.18.38-clk` → `6.18.39-clk`), rebooted — `rpm -q kernel` truthful, doctor PASS,
dmesg gate PASS, vLLM serve-gate GATE-PASS. **Honest edge:** `install-baremetal.sh` (the NVMe install)
is not clean-room-validated — see [`../use/install.md`](../use/install.md).
