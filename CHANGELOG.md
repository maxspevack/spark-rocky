# Changelog

All notable changes to **spark-rocky**. Format follows [Keep a Changelog](https://keepachangelog.com).
Releases are GPG-signed Live-USB images served at `gs://spark-rocky`, tagged `spark-rocky-live-<date>` and
published as GitHub Releases. Soft-launched and **unsupported** — a personal-repo release, provided as-is.

The release invariant is **served == tag == HEAD** (enforced by `scripts/07-verify-release.sh`, #35): the
bytes in the bucket match the git tag they were built from. Each release below names the kernel release it
ships (`uname -r`).

## [spark-rocky-live-20260616] — 2026-06-16 · `6.18.35-64k`

The 64k-page, state-of-the-art release. Same thesis (Rocky 10.2 + a stock upstream 6.18 kernel + the open
NVIDIA driver, zero carried patches), now with an opinionated page-size choice and a hardened build process.

### Changed
- **Page size is now 64k** (`CONFIG_ARM64_64K_PAGES`) — the opinionated default for the GB10 concurrent
  AI-serving workload (a measurable win on concurrent + deep-context cells; rationale + data in
  [`docs/build/platform-deltas.md`](docs/build/platform-deltas.md)). Pinned as `PAGE_SIZE=64k` in
  `config/versions.env`, threaded through `01`→`05` via the derived `KREL`, and **fail-closed gated** in `05`
  (a 64k pin cannot ship a 4k image). The served image and kernel are now `6.18.35-64k`; `uname -r` shows it.
  Build 4k by flipping the one pin.
- Docs reorganized into three stories — [`docs/use`](docs/use), [`docs/build`](docs/build),
  [`docs/benchmark`](docs/benchmark).
- `05` packaging gate now asserts **every** image-defining property (page size, the boot-hygiene cmdline,
  mlx5 blacklist, swap/firstboot masks, baked scripts) — not just a subset.
- `validate.sh` is now the box **doctor**: provenance (running kernel/driver/page size match what was built)
  + the stack (open driver, `nvidia-smi`, a real CUDA kernel) + runtime boot hygiene.

### Added
- `scripts/flash.sh` — one command: download → verify the GPG signature against the pinned key fingerprint →
  guarded write to a USB (refuses any non-removable disk).
- `scripts/run-benchmark-matrix.sh` — the canonical ~104-cell `llama-benchy` matrix behind the parity claim,
  encoded once; auto-arms `templog` so every sweep is traced.
- `scripts/drift-check.sh` + `.github/workflows/drift-check.yml` (#24) — the upstream drift sensor: a weekly
  GitHub Actions job opens a `pin-drift` issue when `KVER`/`DRIVER_VER` fall behind. The "when to rebuild"
  trigger; detect-and-signal only.
- `tests/run-tests.sh` + `make test` + a CI workflow — script syntax + machine-independent logic, gating CI.
- vLLM serving images pinned by digest (#28); `proof.md` states the stock-host coordinates + the
  CUDA-held-constant rigor.

### Removed
- The `#25` fail-closed thermal watchdog — the wrong tool for an attended, single-party, self-throttling box,
  and broken on the GB10 (no absolute slowdown-temp spec). `templog` (passive trace) is kept; the legitimate
  "don't trust a throttled run" requirement is re-filed as post-hoc detection (#43).

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
