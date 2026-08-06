# Build the Live USB from source

How deliverable #1 is made, and how to rebuild it yourself. Everything carries **zero source patches** — the only inputs we author are a kernel `.config` and these scripts. To install the result on the NVMe, see [`../use/install.md`](../use/install.md); the release process and the debug hatch are sections at the end of this page.

## Prerequisites (build host)
- An **aarch64** Linux host with **Docker** — the kernel and the open module build in `rockylinux:10` containers, so the host toolchain doesn't matter. A second DGX Spark, or any ARM box, works.
- The NVIDIA driver `.run` (the `DRIVER_VER` pinned in `versions.env`) — **fetched automatically by `02b` if absent**, verified fail-closed against `DRIVER_SHA256`. Network access for Rocky packages + CUDA.
- ~40 GB free for the rootfs + image.

## The pipeline (run in order)
All versions are pinned in one place, [`../../config/versions.env`](../../config/versions.env) (`KERNEL_SOURCE` — **`clk` is the default**, `CLK_COMMIT`, the `kernelorg` A/B pins `KVER`/`KCONFIG`/`KERNEL_SHA256`, `DRIVER_VER`+`DRIVER_SHA256`, `ROCKY_RELEASEVER`, and **`PAGE_SIZE`** — currently `4k`; 64k was reverted 2026-07-17 when 64k serves faulted, root-caused 2026-07-31 to an NVIDIA open-driver DMA-submap defect ([open-gpu-kernel-modules#1269](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1269), ours) and gate-held via `DRIVER_64K_SAFE`; see [platform-deltas](platform-deltas.md#page-size--64k-is-the-destination-4k-is-what-ships-and-a-gate-holds-the-line-65-80-81)). Every script sources it; bumping a pin and rebuilding is the whole "stay current" mechanism (below). The kernel release is derived by `make kernelrelease`: clk builds carry the **`-clk` lineage suffix** (`uname -r` = `6.18.42-clk` — uname states *where the source came from*, the distro convention), while `PAGE_SIZE` only flips the `CONFIG_ARM64_4K_PAGES`/`_64K_PAGES` symbol (config properties never ride uname). Integrity models differ honestly per source: kernel.org tarballs verify against a GPG-signed SHA256 pin; the CLK tarball is commit-addressed over TLS (GitHub archive bytes are not byte-stable, so no tarball hash exists to pin).

| Step | Script | Produces |
|---|---|---|
| 1 | `01-build-kernel.sh` | the kernel selected by `KERNEL_SOURCE` — default **clk** (CIQ Linux Kernel @ `CLK_COMMIT`, the CLK tree's own aarch64 config, `-clk` uname lineage), `kernelorg` = the stock-tarball A/B (`KVER` + the GB10 `.config`) — built in `rockylinux:10` **plus the kernel RPM** (`binrpm-pkg`, stripped; see *The kernel is an RPM* below) |
| 2 | `02-build-rootfs.sh` | a current Rocky rootfs (`ROCKY_RELEASEVER`) with that kernel, **dnf-installed from 01's RPM** |
| 2b | `02b-install-gpu-docker.sh` | docker + container toolkit + the **shipping open `.ko`, packaged and dnf-installed as `kmod-nvidia-open-<kver>`** (#77; vermagic-checked against the built kernel release) |
| 2c | `02c-driver-userspace.sh` | driver userspace `DRIVER_VER` (sha256-gated `.run --no-kernel-modules`), packaged + dnf-installed as `nvidia-driver-userspace` (#77) |
| 3 | `03-build-nvidia-open.sh` | **optional verify** — a standalone proof-build of the open module in `rockylinux:10` (el10 gcc 14.3.1), vermagic-asserted; the shipping `.ko` comes from `02b` |
| 4 | `04-build-image.sh` | a bootable Rocky image on the built kernel (flashing to USB is optional; `05`/`06` package + sign it for release) |

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
- **NEVRA provenance.** The rpm is named by the kernel's own mkspec: `kernel-6.18.42_clk-1.aarch64` —
  rpm forbids dashes in `Version`, so the `-clk` lineage suffix sanitizes to `_clk` **in the NEVRA
  only**; module paths, `/boot` file names, and `uname -r` all keep the true `6.18.42-clk`.
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
4. Boot, then `proof-of-life.sh`: `uname -r` = the new release (e.g. `6.18.42-clk`), `nvidia-smi`, the CUDA
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

## Release process

How a verified spark-rocky release is cut. The invariant this process exists to protect: **the bytes served == the git tag == the commit that built them.** The failure it prevents is the served image drifting behind the code (a stale, broken image being served while the fixes sit in `main`).

### Cut a release

Run on the Spark (aarch64 — `05` chroots into the image):

1. **Build from HEAD.** `01`→`05` (or `04`+`05` when the kernel, rootfs, and driver are unchanged). The `05` packaging gate is fail-closed: it re-verifies every hardening step against the mounted image and the manifest, and aborts without emitting a checksum if anything is wrong. **`GIT_COMMIT` is RESOLVED, never typed:** `GIT_COMMIT=$(git rev-list -n1 <the release commit/tag>)` — at the 20260723 cut a hand-typed SHA sharing a 7-char prefix with the real commit put wrong provenance in the manifest; `07-verify` caught it, a re-package fixed it, and this sentence prevents it. **Third-party currency:** run the maintenance protocol in [`THIRD_PARTY.md`](../../THIRD_PARTY.md) (fork mirrors pure + current, pin files agree with the box, no pending-issue rows gone stale) — findings fix in the release commit, not after.
2. **SERVE GATE (mandatory since #65/#67).** Put the built kernel on the metal (`upgrade-metal.sh`), reboot to a clean GPU pool, and run:
   ```
   scripts/serve-gate.sh          # brings up the pinned vllm-node, waits for /health 200 + a served model
   ```
   It must print `GATE-PASS`. This exercises the large (~90 GB) KV-cache allocation that `05` and `validate.sh`'s `vectorAdd` do **not** — the exact path the 64k regression ([#65](https://github.com/maxspevack/spark-rocky/issues/65)) faulted on. **A release that has not passed the serve gate on its own kernel is not signable.** `vectorAdd` green is necessary, not sufficient.
2b. **BOOT GATE (mandatory since #86; first enforced on the 20260805 release).** From the operator
   machine, boot the candidate ON HARDWARE and validate it as a booted artifact:
   ```
   BOOT_GATE_HOST=<box> scripts/05b-boot-gate.sh    # flash stick -> BootNext -> doctor over the image's own WiFi -> return
   ```
   It must print `BOOT-GATE: PASS`. This is the only gate that exercises the published bytes as a
   *running system* — releases 20260706–20260723 shipped a WiFi radio the OS could not drive with every
   mounted-image gate green (#84). The armed stick differs from the artifact by exactly three injected
   files (WiFi profile, ssh key, self-return unit); the artifact that gets signed is untouched. **A
   release that has not passed the boot gate on its own bytes is not signable.**

3. **Sign**, on the host that holds the release key: `OUTDIR=<vend-dir> scripts/06-sign-release.sh`. Produces the GPG-clearsigned `CHECKSUM` and exports the public key. The passphrase comes from the human via pinentry; it is never scripted.
4. **Tag the build commit:**
   ```
   git tag -f spark-rocky-live-<YYYYMMDD> <commit>
   git push -f origin spark-rocky-live-<YYYYMMDD>
   ```
5. **Upload** the artifacts (`.raw.xz`, the **three rpms** — kernel #59, `kmod-nvidia-open` + `nvidia-driver-userspace` #77, `CHECKSUM`, `BUILD-MANIFEST.txt`, public key) to the release bucket. **Removing the superseded image + manifest pair is part of this step, not optional cleanup** — a stale sibling manifest in the bucket makes `07-verify` fail loudly by design (#78: at the 20260724 cut the leftover 20260723 pair produced four VERIFY-FAILs against a correctly-served release and sent the diagnosis chasing the wrong suspect).
6. **Verify, fail-closed:**
   ```
   scripts/07-verify-release.sh spark-rocky-live-<YYYYMMDD>
   ```
   It must print `RELEASE-INTEGRITY: OK` — served commit == tag, Good signature from the release key, and the served image's sha is the one inside the signed CHECKSUM. **Do not announce a release until this is green.**

### The tag's contract

`spark-rocky-live-<YYYYMMDD>` points at the commit that built the served image. `07-verify-release.sh` is its only consumer and its enforcer: `served == tag`. HEAD advancing past the tag is allowed — you can release tag N and keep committing toward N+1 — so `07-verify` treats that as a warning, not a failure. Re-cut and re-tag deliberately when those commits should ship.

### Rollback

Re-point the tag at the prior commit, re-upload the prior artifacts, and run `07-verify-release.sh` against the tag. It confirms the rollback the same way it confirms a release. Minutes, not hours.

## Debug access strategy

The vended image is **locked by default**: no `authorized_keys`, `PasswordAuthentication no`, root SSH key-only (`prohibit-password`). Nobody — not even the maintainer — can SSH in unless access is explicitly granted. That's deliberate; a vended image shouldn't trust anyone.

But debugging has to be **easy**, or a stuck test user just gives up. So there are two paths, both using a **dedicated** debug key (`config/debug-authorized_keys`, public; the private key is the maintainer's, off-repo, and is *not* a personal key).

### For the test user — the happy path needs nothing

Boot the USB → it **auto-logs-in to a root shell** (no typing) → run `validate.sh` → file the result. No SSH, no keys, no passwords. That's the whole experience.

### For the test user — if something breaks and we need to look

**Run one line** (we'll give it to you in the issue):

```
bash /root/spark-rocky-debug-enable.sh
```

It authorizes the maintainer's dedicated debug key and prints what to do next (tell us the box's IP). Then we SSH in and debug. Undo any time: `rm /root/.ssh/authorized_keys`. That's it — one command, no key to type. The image stays locked until you choose to run it.

### For the maintainer — debugging our own builds

Build with `DEBUG=1`:

```
DEBUG=1 scripts/04-build-image.sh     # injects the dedicated debug key + an /etc/spark-rocky-debug-hatch marker
```

The debug key is baked in, so we SSH straight into our own test boots. **The marker makes the image un-releasable:** `05-package-image.sh` aborts (no checksum, no signature) if `/etc/spark-rocky-debug-hatch` is present and `DEBUG` isn't explicitly set — a debug build can never be signed and shipped as a release by accident.

### The key

- `config/debug-authorized_keys` — public keys only, one per authorized debugger. Safe to commit.
- The matching **private** keys live with each debugger (the maintainer's is in `~/.ssh`, generated for this purpose, **not** a personal key). No shared private key.
- **Revoke** by deleting a line and rebuilding. No PKI, no CA — right-sized for one maintainer + a handful of validators.

### Shipping posture (decided 2026-06-29)

The release posture is soft-launched and unsupported with no broadcast (#29 closed 2026-06-29), and the
hatch **ships as-is**: a documented maintainer opt-in, locked by default, with the un-releasable-DEBUG-build
gate in `05` holding regardless. Revisit only if the broadcast posture ever changes — the question then is
whether the convenience opt-in ships to strangers, and this section is where that decision gets recorded.
