# Changelog

All notable changes to **spark-rocky**. Format follows [Keep a Changelog](https://keepachangelog.com).
Releases are GPG-signed Live-USB images served at `gs://spark-rocky`, tagged `spark-rocky-live-<date>` and
published as GitHub Releases. Soft-launched and **unsupported** — a personal-repo release, provided as-is.

The release invariant is **served == tag == HEAD** (enforced by `scripts/07-verify-release.sh`, #35): the
bytes in the bucket match the git tag they were built from. Each release below names the kernel release it
ships (`uname -r`).

## [Unreleased]

**The benchmark-provenance release: parity re-proven on a runtime anyone can pull byte-identically.**
Kernel, driver, and platform firmware are unchanged and remain upstream-latest (`6.18.39-clk` ·
610.43.03 · LVFS-current, all drift rows MATCH); the payload delta is a fresh Rocky 10.2 userspace at
build time and the serving/benchmark stack maturing around the image.

### Added
- **Serving pins, generation 2** (#71): the benchmark runtime now pins a **permanent dated
  [`spark-arena/dgx-vllm`](https://github.com/spark-arena/dgx-vllm) mirror tag + digest**
  (`config/serving-images.env`; vLLM 0.23.1, FlashInfer 0.6.15) — the "spark-arena pins no vLLM
  version" confound is closed from our side. The June digests stay as the receipt-era baseline.
- **Parity holds on the current runtime**: full 104-cell 0.8B matrix on `6.18.39-clk` + the pinned
  image — **median 1.010× vs published** (decode 1.010×, prefill 1.011×), throttle-check CLEAN
  (`receipts/reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt`). The June prefill deficit (0.75–0.93×) is
  thereby proven **vLLM-version drift, not the host**; #18 narrowed to one localized residual.
- **The board's own harness validated on this host** (#72): sparkrun 0.2.40 end-to-end — registry
  recipes, serve orchestration, the official spark-arena-v2 profile through llama-benchy 0.4.0,
  `arena --local-test` account-free. Divergences documented (`docs/benchmark/sparkrun-harness.md`);
  one real upstream bug found and filed with root cause:
  [spark-arena/sparkrun#225](https://github.com/spark-arena/sparkrun/issues/225).
- **Drift sensor `SERVING` row** (#24/#71): the mirror-tag pin's age is watched (INFO under 31 days,
  DRIFT past a month) — validated locally and in a live Actions run.

### Changed
- **`serve-gate.sh` drops page caches in preflight**: on unified memory `cudaMemGetInfo` reports
  `MemFree`, so a large image pull before the gate starved vLLM's startup check (hit live during #71).
  The gate is now deterministic regardless of what ran before it.
- **Docs currency pass**: all index/benchmark docs reflect the above; the gen-2 recipe variant is
  committed (`recipes/qwen3.5-0.8b-arena-2026072302.yaml`); `THIRD_PARTY.md` is the supply-chain map
  (prose-pin rule, test-enforced) with the spark-arena ecosystem forked and mirror-synced.

## [spark-rocky-live-20260723] — 2026-07-23 · `6.18.39-clk` (4k pages) — everything as RPMs

**The release-engineering release: every byte on the box answers to `rpm -qf`.** The kernel, the open
NVIDIA modules, the driver userspace + GSP firmware, and the WiFi firmware are all dnf-installable
packages — built by the pipeline or pulled from Rocky — vended next to the image and bound into the
signed CHECKSUM. Plus a stay-current kernel bump and two full-repo review passes.

### Changed
- **Kernel `6.18.38-clk` → `6.18.39-clk`** (`CLK_COMMIT` → `ceb41d6`, the drift sensor's trigger, #69).
  A routine 6.18.y stable bump: the `01` SIGNAL-READOUT is symbol-for-symbol identical to `.38`;
  serve-gated on the metal. Parity remains benched on `.38-clk` (#61) + the June stock host.
- **The kernel ships as an RPM** (#59): built in one `binrpm-pkg` invocation (`Release=1`
  deterministic), dnf-installed into the image and onto the metal — **`rpm -q kernel` is truthful on
  the booted box**; NEVRA in the manifest + provenance stamp; served from the bucket, CHECKSUM-bound,
  `07-verify`-enforced. NEVRA note: rpm forbids dashes in `Version`, so `6.18.39-clk` sanitizes to
  `kernel-6.18.39_clk-N` in the package name only; uname/module paths//boot names keep the true `-clk`.
- **The NVIDIA stack is RPM-owned** (#77): `kmod-nvidia-open-<kver>` (the open `.ko` set + the boot
  auto-load config; kver in the Name for kernel-style coexistence) and `nvidia-driver-userspace`
  (the `.run` payload incl. GSP firmware, packaged from the ground-truth path-diff of the actual
  install — self-regenerating per driver bump). glvnd comes from Rocky's `libglvnd-*` rpms, not the
  installer (rpm itself caught the first attempt's file conflict on the metal — working as designed).
- **MT7925 WiFi/BT firmware, rpm-pure** (#64): stock Rocky `mt7xxx-firmware` + `wireless-regdb`, with
  `FW_LOADER_COMPRESS_ZSTD` enabled (the actual root cause — the "platform early-probe quirk" was a
  misdiagnosis); the radios initialize at boot (dmesg census 19 → 18, the radio-failure class gone).
- The doctor gains the 8 GiB managed-memory check (#63) and the three rpm-ownership checks; the full
  #70 audit landed (33 findings fixed, a 559 GB metal debris purge, build-speed work: single-invocation
  binrpm, dnf-cache mounts, per-stage timing); two independent full-repo reviews (scripts + docs)
  fixed 1 doc-CRITICAL + 22 MAJORs — incl. fail-closed config asserts on the two documented mines,
  a no-eval `07-verify` with a pinned signature fingerprint, and a single-release vend gate in `06`.

### Validated
- Metal in-place upgrade via the dnf/rpm path (`6.18.38-clk` → `6.18.39-clk`), rebooted: `rpm -q`
  truthful for kernel + kmod + userspace, doctor PASS (incl. vectorAdd + the full-8-GiB managed-memory
  round-trip), dmesg gate PASS (19 → 18, every delta explained), **vLLM serve-gate GATE-PASS** (#67).
- The image: rootfs fully rpm-owned with fail-closed verifies at every install; `IMAGE-VERIFY-OK`.

### Notes
- Supersedes [spark-rocky-live-20260717b]. Same `served == tag == HEAD` gate (`07-verify`, #35), now
  also binding the three served rpms.

## [spark-rocky-live-20260717b] — 2026-07-17 · `6.18.38-clk` (4k pages) — 64k reverted

> **Correction (2026-07-22):** the "kernel regression from `6.18.37`" root cause below was **falsified** —
> the exact June stack (kernel `6.18.35` + 64k + driver `.02` + June firmware), fully restored, still
> faults. Kernel/driver/firmware exonerated; it is a CUDA-level large-allocation fault under 64k, hunt
> deferred ([#68](https://github.com/maxspevack/spark-rocky/issues/68)). The 4k revert stands as the
> resolution. Entry below preserved as written.

**Page size reverted to 4k; this is a correctness fix over 20260717.** A kernel regression from `6.18.37`
on faults the **vLLM serve** under 64k pages — a GPU Xid 31 MMU fault in the ~90 GB KV-cache allocation
([#65](https://github.com/maxspevack/spark-rocky/issues/65)). It shipped undetected in four 64k releases
because validation only ran `vectorAdd`, which never touches the large-allocation path. `6.18.38`/4k serves
clean; the CLK kernel and driver are otherwise unchanged from 20260717.

### Changed
- **`PAGE_SIZE=64k` → `4k`** ([#66](https://github.com/maxspevack/spark-rocky/issues/66)). uname stays
  `6.18.38-clk`; `getconf PAGESIZE` is now `4096`. The 64k concurrent-serving win (measured on the
  then-working `6.18.35`) is real but currently unreachable — parked behind the regression, restored once
  `6.18.35→.37→.38` is bisected and fixed upstream ([#68](https://github.com/maxspevack/spark-rocky/issues/68)).
- Docs reframed (`platform-deltas`, README, `proof`, `software-stack`, `build`, `running`, `scoreboard`):
  64k is a reverted tuning choice, not the current default.

### Validated
- Isolated by same-box single-variable A/B on the GB10 (see #65): `6.18.34`/4k, `6.18.38`/4k both **serve**;
  `6.18.38`/64k **faults**; `6.18.35`/64k served in June. Kernel source, driver, and firmware all controlled
  out. This release's image was **serve-gated** — the pinned `vllm-node` brought up on it, `/health` 200 with
  the KV cache allocated, before signing ([#67](https://github.com/maxspevack/spark-rocky/issues/67)).

### Notes
- Supersedes [spark-rocky-live-20260717], which ships the 64k serve regression and is withdrawn. Same
  `served == tag == HEAD` gate (`07-verify`, #35).

## [spark-rocky-live-20260717] — 2026-07-17 · `6.18.38-clk` (64k pages) — the CLK release · **SUPERSEDED (#65: 64k serve regression)**

**The shipped kernel is now the CIQ Linux Kernel.** `KERNEL_SOURCE=clk` is the default, pinned to the
public GPL [`ctrliq/kernel-src-tree`](https://github.com/ctrliq/kernel-src-tree) `ciq-6.18.y` @ `b1a607d`,
built unmodified with its own aarch64 config — and the kernel says so itself: `uname -r` → **`6.18.38-clk`**
(the lineage suffix, `.el9`-style), the GRUB menu reads `Rocky + 6.18.38-clk (GB10)`, and the provenance
stamp carries `kernel_source=clk` + the exact commit. Stock kernel.org stays one pin-flip away
(`KERNEL_SOURCE=kernelorg`) — it is where the parity receipts were recorded, and both trees run the GB10
with zero patches carried by this repo.

### Changed
- **CLK default + lineage identity.** The kernel release is derived (`make kernelrelease`) and propagates
  through the fail-closed `build.env` handoff into every stage — modules dir, vermagic, vmlinuz name, GRUB,
  and the `05` stamps (`kernel_source=`, `clk_commit=`). The uname doctrine is refined, not reversed:
  lineage rides uname; config properties (64k) never do.
- **The refresh trigger is CLK, not kernel.org.** `drift-check` fires on `ciq-6.18.y` moving past
  `CLK_COMMIT`; kernel.org is demoted to an INFO row (context for how far CLK trails upstream).
- **Fully current at cut time, verified zero-pending** (image and metal): Rocky 10.2 userspace current
  (`dnf check-update` = 0 in the image rootfs and on the box) and **platform firmware current via stock
  fwupd/LVFS — UEFI `0x02009b0b` + EC `0x03000508` applied**, `fwupdmgr get-updates` clean. The new SoC
  firmware resolved six long-standing platform `err/crit` lines (see `docs/build/dmesg-baseline.md`).
- **#60 fixed:** the ESP GUID pin + backup-GPT relocation moved from sgdisk (fail-open: gdisk uninstallable
  on the metal, three silently-unpinned flashes) to **sfdisk, fail-closed, read-back-verified**.
- **Secure Boot posture documented** (`running.md`/`install.md`/`build.md`): SB must be disabled (unsigned
  custom kernel; signing machinery deliberately neutralized for reproducibility); the release's trust
  anchor is the GPG-signed artifact, not boot-chain attestation.

### Validated
- The CLK path was validated end-to-end on the GB10 before the flip (the 2026-07-17 overnight session,
  #52/#54): boot, open driver 610.43.03 loaded, CUDA, and an 8 GiB `cudaMallocManaged` round-trip —
  which also proved `DEVICE_PRIVATE` is **not load-bearing** on the coherent GB10 (`pageableMemoryAccess=1`).
- This release's image: built clean (the `MODULE_SIG_ALL` fix in-pipeline), metal upgraded in place to
  `6.18.38-clk` (kernelorg `6.18.38` kept as the GRUB fallback), rebooted on the new firmware: `nvidia-smi`
  + GSP live, CUDA `vectorAdd` PASS, dmesg census **22 → 19** with every direction-change explained.
- Parity receipts remain recorded on the stock-mainline host, qualified in `proof.md`/`software-stack.md`;
  benchmark validation of the CLK default is queued as #61.

### Notes
- Supersedes [spark-rocky-live-20260716]. Same `served == tag == HEAD` integrity gate (`07-verify`, #35).

## [spark-rocky-live-20260716] — 2026-07-16 · `6.18.38` (64k pages)

A stay-current release (#58): same thesis — Rocky 10.2 + a stock upstream 6.18 kernel + the open NVIDIA
driver, **zero carried patches**, 64k pages — with the driver moved to the latest upstream point release and
the `.run` brought under the same pinned-hash discipline as the kernel tarball.

### Changed
- **NVIDIA open driver → `610.43.03`** (from `610.43.02`; upstream published 2026-07-07). The open-module
  source delta is one upstream commit: version headers + a DisplayPort connector fix (`dp_connectorimpl.cpp`),
  dormant on this compute-only image (`nvidia-drm.modeset=0`). GSP firmware rides the driver → `610.43.03`.
  Kernel stays `6.18.38` (still the latest 6.18.y longterm at cut time); Rocky `10.2` + `CUDA_VER=13-0`
  unchanged.
- **The driver `.run` is now hash-pinned** (`DRIVER_SHA256` in `versions.env`), closing the asymmetry with
  `KERNEL_SHA256`: NVIDIA publishes no signed checksums for the `.run`, so the pin is trust-on-first-download
  (TLS + the `.run`'s embedded `--check` self-test, both verified at bump time) — and `02b`/`02c` fail closed
  on any mismatch, so every rebuild consumes byte-identical driver input. `make test` grows 56 → 60 (pin
  format + both consumer gates).
- Parity receipts remain benched on `610.43.02` — a driver point bump does not re-run the matrix; the
  receipt-vs-shipped coordinates are qualified in `proof.md` / `software-stack.md` (the same treatment as
  "benched on 6.18.34").

### Validated
- On the GB10 metal: the new `.ko` set (vermagic `6.18.38`) + `.run` userspace + a rebuilt initramfs were
  installed in place (the `610.43.02` modules + `.run` staged as an offline rollback), rebooted; `nvidia-smi`
  reports driver + GSP `610.43.03`, CUDA `vectorAdd` PASS. The `610.43.02 → 610.43.03` `dmesg` baseline-diff
  gate was clean — identical `err/crit` set, zero new lines ([`docs/build/dmesg-baseline.md`](docs/build/dmesg-baseline.md)).

### Notes
- Supersedes [spark-rocky-live-20260706]. Same `served == tag == HEAD` integrity gate (`07-verify`, #35).

## [spark-rocky-live-20260706] — 2026-07-06 · `6.18.38` (64k pages)

A stay-current release (#57/#26): same thesis — Rocky 10.2 + a stock upstream 6.18 kernel + the open NVIDIA
driver 610.43.02, **zero carried patches**, 64k pages — moved to the latest upstream point release, and the
Rocky 10.2 userspace refreshed.

### Changed
- **Kernel → upstream `6.18.38`** (from `6.18.37`), via the documented stay-current mechanism: bump `KVER` + a
  `KERNEL_SHA256` taken from kernel.org's **GPG-signed `sha256sums.asc`** (verified against the kernel.org
  autosigner key `B886 8C80 BA62 A1FF FAF5 FDA9 632D 3A06 589D A6B1`; sha `ac26e508…`), then rebuild.
  `olddefconfig` carried the GB10 `.config` forward; the `01` SIGNAL-READOUT diffed **symbol-for-symbol
  identical to `6.18.37`** — every GB10 enablement symbol unchanged, `CONFIG_ARM64_64K_PAGES=y` preserved
  (`uname -r` = `6.18.38`, `getconf PAGESIZE` = `65536`).
- **Rocky 10.2 userspace refreshed** to the current package set (it floats — `02` installs current packages at
  `ROCKY_RELEASEVER=10`). Driver stays `610.43.02`, CUDA pin stays `13-0` (both upstream-current).

### Validated
- Boot-validated on the GB10: the NVMe metal was upgraded in place to 6.18.38 (`upgrade-metal.sh`, non-destructive,
  6.18.37 kept as the GRUB fallback) + a userspace `dnf update`, rebooted, and `proof-of-life` PASS (open driver
  auto-loads, `nvidia-smi`, CUDA `vectorAdd`). The `6.18.37 → 6.18.38` `dmesg` baseline-diff gate was clean — no
  new `err/crit` line beyond the documented platform baseline ([`docs/build/dmesg-baseline.md`](docs/build/dmesg-baseline.md)).

### Notes
- Supersedes [spark-rocky-live-20260629]. Same `served == tag == HEAD` integrity gate (`07-verify`, #35).

## [spark-rocky-live-20260629] — 2026-06-29 · `6.18.37` (64k pages)

A stay-current release (#55/#26): same thesis — Rocky 10.2 + a stock upstream 6.18 kernel + the open NVIDIA
driver 610.43.02, **zero carried patches**, 64k pages — moved forward to the latest upstream point release,
with the build's CUDA pin made explicit and the boot `dmesg` baseline documented.

### Changed
- **Kernel → upstream `6.18.37`** (from `6.18.35`), via the documented stay-current mechanism: bump `KVER` + a
  `KERNEL_SHA256` taken from kernel.org's **GPG-signed `sha256sums.asc`** (verified against the kernel.org
  autosigner key `B886 8C80 BA62 A1FF FAF5 FDA9 632D 3A06 589D A6B1`), then rebuild. `olddefconfig` carried the
  GB10 `.config` forward; the `01` SIGNAL-READOUT was diffed symbol-for-symbol against `6.18.35` — **every GB10
  enablement symbol holds the same value, nothing dropped** — and `CONFIG_ARM64_64K_PAGES=y` is preserved
  (`uname -r` stays the plain `6.18.37`, `getconf PAGESIZE` = `65536`).
- **Rocky 10.2 userspace refreshed** to the current package set (it floats — `02` installs current packages at
  `ROCKY_RELEASEVER=10`). The NVIDIA open driver stays at `610.43.02` (verified upstream-latest).
- **CUDA pinned explicitly.** The image's proof-of-life CUDA compiler (`02`'s `nvcc` + `cudart`) is now a
  reviewable `CUDA_VER=13-0` pin in `config/versions.env` instead of a package-name hardcode that silently
  rotted. The value is held at `13.0` — identical to the digest-pinned serving-container CUDA (#28), so the
  parity narrative is unchanged. (This is *not* the parity CUDA; that lives in the serving containers and is out
  of scope for a Live-USB release.) `drift-check.sh`'s header is corrected to state CUDA is pinned, not floating.

### Added
- [`docs/build/dmesg-baseline.md`](docs/build/dmesg-baseline.md) — the GB10 boot `err/crit` census, each line
  root-caused and marked benign, so future builds diff against it instead of re-litigating. It records the
  `6.18.35 → 6.18.37` baseline-diff gate: identical except three WiFi/BT firmware-missing lines, which are a
  `linux-firmware` subpackage-split artifact (unused radios on a wired box), **not** a kernel regression.

### Notes
- Supersedes [spark-rocky-live-20260617]. Same `served == tag == HEAD` integrity gate (`07-verify`, #35).

## [spark-rocky-live-20260617] — 2026-06-17 · `6.18.35` (64k pages)

The 64k-page, state-of-the-art release. Same thesis (Rocky 10.2 + a stock upstream 6.18 kernel + the open
NVIDIA driver, zero carried patches), now with an opinionated page-size choice and a hardened, audited build.

### Changed
- **Page size is now 64k** (`CONFIG_ARM64_64K_PAGES`) — the opinionated default for the GB10 concurrent
  AI-serving workload (a measurable win on concurrent + deep-context cells; rationale + data in
  [`docs/build/platform-deltas.md`](docs/build/platform-deltas.md)). Pinned as `PAGE_SIZE=64k` in
  `config/versions.env` and **fail-closed gated** in `05` on the `.config` symbol (a 64k pin cannot ship a 4k
  image). The page size is a config + provenance-stamp property; `uname -r` stays the plain, standard
  `6.18.35` (no `-64k` suffix — the kernel carries no `LOCALVERSION`), and `getconf PAGESIZE` reports `65536`.
  Build 4k by flipping the one pin.
- `validate.sh` is now a **self-contained** box doctor — it compiles + runs its own CUDA proof (no dependency
  on a sibling script, no misleading "not present" message) and drops the runtime issue-URL.
- `05` asserts **every** image-defining property (page size, boot-hygiene cmdline, mlx5 blacklist,
  swap/firstboot masks, baked scripts); `04` now verifies the boot-hygiene + debug hatch in-build too, so a
  direct-flash is gated, not only the release artifact.
- Docs reorganized into three stories — [`docs/use`](docs/use), [`docs/build`](docs/build),
  [`docs/benchmark`](docs/benchmark).

### Fixed
- **#44** — the build silently shipped a **gzip** initramfs. Root cause: `04`'s chroot had no working
  `/etc/resolv.conf` (a `--installroot` rootfs ships none), so the chroot `dnf` couldn't resolve the Rocky
  mirror and failed silently under the old `|| true` — `zstd` was never installed and dracut fell back to gzip
  (exit 0; the size-only check passed). Fixed three ways: `04` copies the host resolv.conf into the chroot,
  hard-gates `zstd` presence before dracut, and verifies the initramfs is zstd by its magic bytes.
- **Debug hatch** — `04` read `config/debug-authorized_keys` via `$W/config` instead of `$HERE/../config`, so
  any build with `W=` ≠ repo root silently skipped baking `/root/spark-rocky-debug-enable.sh`. Fixed to the
  script-relative path; `04` now verifies the enabler was baked.
- `proof-of-life.sh` no longer masks an `nvcc` compile failure behind a `tail` pipe; `install-baremetal.sh`
  matches the USB by removable-disk (not a hardcoded `/dev/sda2`) and aborts on a failed rsync instead of
  installing grub onto a half-copied NVMe.
- **mlx5 / boot hygiene (#30)** — the unused ConnectX driver coldplug-loaded at ~2 s in the `--no-hostonly`
  initramfs, *before* the rootfs blacklist applied (so the doctor flagged it and dmesg carried its init).
  `04` now omits mlx5 from the initramfs (`--omit-drivers`); the rootfs blacklist keeps it off afterward.
- **#45 autologin** — the console blanked and autologin restarted once before holding, because fbcon deferred
  taking the console until ~1 min in (after getty started). `fbcon=nodefer` makes fbcon take the console
  immediately, before getty — no mid-session switch.

### Added
- `tests/run-tests.sh` + `make test` + CI now check **behavioral invariants** (the suffix-drop stays done,
  the debug-hatch path is script-relative, `zstd` is gated, the doctor is self-contained, `versions.env` is
  well-formed) — not just `bash -n`. The class of regression that produced this release's bugs now fails CI.
- `scripts/flash.sh` — one command: download → verify the GPG signature against the pinned key fingerprint →
  guarded write to a USB (refuses any non-removable disk).
- `scripts/run-benchmark-matrix.sh` — the canonical ~104-cell `llama-benchy` matrix behind the parity claim,
  encoded once; auto-arms `templog` so every sweep is traced.
- `scripts/drift-check.sh` + `.github/workflows/drift-check.yml` (#24) — the upstream drift sensor: a weekly
  GitHub Actions job opens a `pin-drift` issue when `KVER`/`DRIVER_VER` fall behind. Detect-and-signal only.
- vLLM serving images pinned by digest (#28); `proof.md` states the stock-host coordinates + the
  CUDA-held-constant rigor.

### Removed
- The `#25` fail-closed thermal watchdog — the wrong tool for an attended, single-party, self-throttling box,
  and broken on the GB10 (no absolute slowdown-temp spec). `templog` (passive trace) is kept; the legitimate
  "don't trust a throttled run" requirement is re-filed as post-hoc detection (#43).
- Garbage-collected dead weight: the 8 one-time `scripts/bringup/` artifacts, the 362 KB stock-DGX
  `config/dgx-6.17-nvidia.config` baseline, and two orphan `data/` recipe duplicates.

## [spark-rocky-live-20260612] — 2026-06-12 · `6.18.35` (4k)

The first signed, reproducible Live-USB release: **Rocky Linux 10.2 + a stock upstream 6.18.35 kernel (4k
pages) + the open NVIDIA driver 610.43.02, zero carried patches**, reproducing published single-host
spark-arena.com benchmarks at parity.

### Added
- The `01`→`06` build/sign pipeline (kernel → rootfs → CUDA/docker → open module → image → sign), runnable
  on the Spark; the GB10 `.config` + the pinned `versions.env`.
- A bootable, non-destructive Live USB: boot it, run `/root/validate.sh` (kernel + open driver + a real CUDA
  kernel → PASS/FAIL); install to the NVMe is a separate, deliberate step.
- Boot hardened to ~80s: `nvidia-drm.modeset=0` (kills the `WQ_UNBOUND` flood + console blackout), console
  autologin, `mlx5_core` blacklist, `systemd-firstboot` mask, pre-built `ld.so.cache`, and the first-boot
  login fixes (machine-id, getty).
- A locked-image maintainer debug hatch (dedicated key; `05` refuses to sign a DEBUG image).
- The proof: four single-host models reproduced at parity, with the controlled-experiment (changed-vs-held-
  constant) framing and committed receipts.
- Release integrity: GPG-signed `CHECKSUM` (ed25519, fp `71C1 6676 F9D4 0A4C E0C6 EB66 08B1 4BC3 9831 1101`),
  served at `gs://spark-rocky`, with the `served == tag == HEAD` gate (#35).

[spark-rocky-live-20260717b]: https://github.com/maxspevack/spark-rocky/releases/tag/spark-rocky-live-20260717b
[spark-rocky-live-20260717]: https://github.com/maxspevack/spark-rocky/releases/tag/spark-rocky-live-20260717
[spark-rocky-live-20260716]: https://github.com/maxspevack/spark-rocky/releases/tag/spark-rocky-live-20260716
[spark-rocky-live-20260706]: https://github.com/maxspevack/spark-rocky/releases/tag/spark-rocky-live-20260706
[spark-rocky-live-20260629]: https://github.com/maxspevack/spark-rocky/releases/tag/spark-rocky-live-20260629
[spark-rocky-live-20260617]: https://github.com/maxspevack/spark-rocky/releases/tag/spark-rocky-live-20260617
[spark-rocky-live-20260612]: https://github.com/maxspevack/spark-rocky/releases/tag/spark-rocky-live-20260612
