# Changelog

All notable changes to **spark-rocky**. Format follows [Keep a Changelog](https://keepachangelog.com).
Releases are GPG-signed Live-USB images served at `gs://spark-rocky`, tagged `spark-rocky-live-<date>` and
published as GitHub Releases. Soft-launched and **unsupported** — a personal-repo release, provided as-is.

The release invariant is **served == tag == HEAD** (enforced by `scripts/07-verify-release.sh`, #35): the
bytes in the bucket match the git tag they were built from. Each release below names the kernel release it
ships (`uname -r`).

## [spark-rocky-live-20260616] — 2026-06-16 · `6.18.35` (64k pages)

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

[spark-rocky-live-20260616]: https://github.com/maxspevack/spark-rocky/releases/tag/spark-rocky-live-20260616
[spark-rocky-live-20260612]: https://github.com/maxspevack/spark-rocky/releases/tag/spark-rocky-live-20260612
