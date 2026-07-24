# Platform deltas — an unmodified 6.18 tree + open driver on the GB10

What an unmodified 6.18 kernel tree (the shipped **CLK** default or the stock-mainline A/B path — this
repo patches neither) + the open NVIDIA driver surface on the DGX Spark (GB10) at boot, each line
classified and decided. The project starts from a zero-carried-patch clean room; every divergence is a
deliberate, data-justified tweak — **carried** (tracked here + in [`THIRD_PARTY.md`](third-party.md)) or
**upstreamed**. The pitch is auditability: every tweak is named and reasoned, not inherited from an opaque
vendor image. (The dmesg census below was recorded on the stock-mainline host; the CLK baseline is in
[`dmesg-baseline.md`](dmesg-baseline.md).)

The load-bearing fact: **GPU compute works** — `proof-of-life` runs `vectorAdd` on the GB10 (compute 12.1,
130.7 GB) on the LiveUSB boot of 6.18.35. Everything below is peripheral to that.

## Page size — currently 4k (64k REVERTED, #65)

**We ship a 4k-page kernel** (`CONFIG_ARM64_4K_PAGES`), pinned as `PAGE_SIZE=4k` in
[`config/versions.env`](../../config/versions.env). This is a **2026-07-17 reversal** of what had been the
project's headline opinionated choice (64k). The reversal is a **correctness fix, not a change of opinion on
performance**: under 64k pages, **large CUDA allocations fault** — a GPU Xid 31 MMU fault in the large
(~90 GB) KV-cache allocation ([#65](https://github.com/maxspevack/spark-rocky/issues/65)), reproducible in
~15 lines of pure CUDA (`cudaMalloc` ~90 GB + write). 4k is unaffected and serves clean.

**Not a kernel regression (2026-07-22).** The fault was first read as a kernel change in the `.35→.37`
window (64k on `6.18.35` had served in June; 64k on `6.18.38` faults). Controlled reverts falsified that:
the **exact June stack — kernel `6.18.35` + 64k + driver `610.43.02` + the June firmware — fully restored,
still faults.** Kernel, driver, and firmware are all exonerated; the remaining suspects are host userspace,
the CUDA toolkit, or an NVIDIA CUDA-ARM64-64k bug. The root-cause hunt is **deferred**
([#68](https://github.com/maxspevack/spark-rocky/issues/68)); 4k is the resolution.

**Why 64k was the choice (and why the theory still holds).** The GB10 is a concurrent AI-serving box. 64k
pages cut TLB misses and page-table walks under large memory working sets — the regime this workload lives
in (many concurrent sequences over long contexts → a big KV cache). 4k is the right default for a *general*
host; 64k was the opinionated default for *this* one — until the fault surfaced.

**The performance evidence stands (2026-06-16, on the June `6.18.35`/64k stack).** Full canonical 104-cell
matrix, 35B-A3B-FP8, `6.18.35`/64k vs the 4k baseline: median +2.3%, **35 cells win ≥+5% vs 3 losses**, wins
clustered on concurrent + deep-context cells (`tg128@d65535 (c10)` **1.30×**, `ctx_pp@d4096 (c2)` **1.38×**).
That win was measured while the June stack still served. It is currently unreachable — the perf gain is
*parked behind a correctness bug*, not withdrawn. (Why the June run worked at all is part of #68's open
question.) It shipped undetected in four 64k releases because release validation only ran `vectorAdd`
(a tiny allocation) — the serve gate that now closes that hole is
[#67](https://github.com/maxspevack/spark-rocky/issues/67). Full isolation: [#65](https://github.com/maxspevack/spark-rocky/issues/65).

**Flip back to 64k in `versions.env` (only) if #68's CUDA-level cause is ever found + fixed.**

**How it's enforced (the process, not just a flag).** `PAGE_SIZE` is a pinned, reviewable line; `01` sets the
`CONFIG_ARM64_4K_PAGES` / `_64K_PAGES` symbol from it (with **no** `LOCALVERSION` suffix — the kernel release
stays plain `$KVER`, the standard distro convention); `05`'s fail-closed gate **aborts the release if the
resolved `.config` page size does not match the pin** (the current `4k` pin cannot ship a 64k image, and vice
versa); the provenance stamp records `page_size=4k`; and the `validate.sh` doctor asserts the running
`getconf PAGESIZE` (`4096`) matches what was built. The page size lives in the `.config` symbol + the stamp,
not in a uname tag — so flipping the pin back to 64k after #68 is a one-line, fully-gated change.

## Grounding (measured 2026-06-11)
- **Kernel config has the features on:** `ARM_SMMU_V3_SVA`, `IOMMU_SVA`, `PCI_PRI/PASID/ATS`, `ENERGY_MODEL`,
  `SCHED_CLUSTER` are all `=y`. The SMMU and energy-model warnings are therefore **not** config gaps.
- **Identical delta set on 6.18.34 (NVMe) and 6.18.35 (USB)** — version-independent ⇒ platform/firmware-level,
  not a kernel regression.
- **Firmware is current** (see below) — so the persisting deltas are **not** stale-firmware artifacts; they are
  how stock-mainline + the open driver behave on this platform at its latest firmware.

## Firmware — current, via stock `fwupd` / public LVFS
NVIDIA publishes the GB10 platform firmware (system UEFI, Embedded Controller, USB-C PD) to the **public LVFS**;
stock `fwupd` applies it — no DGX OS, no Enterprise entitlement, no proprietary tool (`fwupdmgr enable-remote
lvfs && fwupdmgr refresh && fwupdmgr upgrade`). As of 2026-07-17 this box is on the **latest published**: UEFI
`0x02009b0b` (the SoC/UEFI+GPU stability package), EC `0x03000508`, USB-C PD `0x00000516` — applied via
capsule-on-disk with stock `fwupd`, `fwupdmgr get-updates` clean after. GPU VBIOS `9A.0B.25.00.00` and GSP
`610.43.03` ride the driver and are current with it.
**Consequence:** parity benchmarks run on the same latest firmware a DGX OS box runs — no firmware confound.

## Ledger
| ID | Delta (dmesg) | Decision | Notes |
|----|---------------|----------|-------|
| L1 | open driver didn't auto-load → `nvidia-smi` failed | **CARRY (assembly), fixed** | `02b` now runs `depmod` + writes `/etc/modules-load.d/nvidia.conf`; build gates assert nvidia is in `modules.dep` |
| L2 | `GPT: alt header not at end of disk` | **CARRY (assembly), fixed** | `04` runs `sgdisk -e` after `dd` (cosmetic; we `dd` a sized image onto a larger stick) |
| L3 | `arm-smmu-v3: PRI will be broken / msi_domain absent` | **BENIGN on current firmware** | Persists at latest firmware; configs are `=y`, so it's the platform ACPI/IORT. The GB10 GPU is NVLink-C2C-coherent (not the PCIe SMMU-SVA path) — compute is unaffected (observed) |
| L4 | `NVDA8800:00 device-creation -16` | **BENIGN on current firmware** | 1 of ~30 NVDA Grace platform devices; the only one that fails (resource conflict); non-critical to compute |
| L5 | `EM: CPUs … same capacity` (×15) | **MEASURE** | Platform ACPI doesn't feed cpu `capacity-dmips-mhz` to the energy model; may change EAS scheduling across X925 vs A725 → possible perf. Quantify with a before/after spark-arena run |
| L6 | `mt7925` WiFi/BT firmware missing | **FIXED (#64)** | `02` now ships the MT7925 + `regulatory.db` blobs **uncompressed** into the rootfs (~2M targeted, not the full `linux-firmware`). A `.zst` load fails at the driver's early probe on this platform; plain `.bin` loads at boot (metal-verified 2026-07-22 — `WM Firmware Version` at ~6.7s, `wlP9s9` up). Wired stays the benchmark default; the radios are now *available*. |
| L7 | `mlx5` ConnectX-7 loads unwanted (unused cluster NIC; on bare hardware it can flood dmesg / "insufficient power") | **CARRY (assembly), fixed** | Multi-node is out of scope, so we don't want the driver loaded. A rootfs blacklist alone is **insufficient**: in a `--no-hostonly` initramfs mlx5 coldplug-loads at ~2s, *before* the blacklist applies. `04` **omits mlx5 from the initramfs** (`--omit-drivers`) so it cannot load early; the rootfs blacklist keeps it off post-switch-root (#30). Re-enable + ship the mlx5 firmware if you ever cable it for clustering |
| L8 | `GICv3 [Firmware Bug] GSI8`, `FF-A IRQ mapping` | **BENIGN on current firmware** | Firmware↔kernel friction the kernel flags and works around; no observed impact |
| L9 | `PCI: OF: of_root NULL` (×8) | **NO-OP** | PCI host bridges come from ACPI on this hybrid ACPI+DT boot; expected |

## Carried kernel cmdline (boot parameters, not source patches)
Inherited from the proven bare-metal box; each is a deliberate boot parameter, not a patch:
- `iommu.passthrough=0` — SMMU does DMA translation rather than bypass (matches the DGX baseline; keeps PCIe
  DMA isolated). The GB10 GPU reaches memory over NVLink-C2C coherence, so GPU compute is unaffected either way.
- `init_on_alloc=0` — disables zero-on-allocation (a small throughput win). This is a single-user benchmark
  host, not a multi-tenant security boundary; revisit if that changes.
- `console=tty0` — console on the attached monitor. (The earlier `console=ttyS0,921600` was dropped: `/dev/ttyS0`
  does not exist on the GB10 and waiting for it hung boot ~90s; `earlycon` below still surfaces early-boot serial.)
- `nvidia-drm.modeset=0` — the GPU does **compute only** (`nvidia-uvm`); it does not take over the display, so the
  console stays on the low-res EFI framebuffer. Deliberate: with the nvidia fbdev console on, the open driver's
  `drm_fb_helper` damage worker flushed the large GPU framebuffer on a bound workqueue every console update
  (`WQ_UNBOUND` warnings) and the handover blacked the monitor for seconds. A compute box needs no GPU-driven
  console; this removes both, with zero effect on CUDA.
- `fbcon=nodefer` — take the framebuffer console over immediately instead of deferring. With `modeset=0` the
  deferral never resolves to a GPU console, so fbcon would otherwise take the simpledrm console ~1 min in,
  *after* getty has started — switching the console under the running autologin and forcing a one-time getty
  restart (a visible screen-blank before login holds). Taking over early keeps the console stable (#45).
- `quiet loglevel=3` — trims the boot console to essentials; paired with `modeset=0` the boot is clean, not a wall
  of warnings.
- `earlycon=uart,mmio32,0x16A00000` — early-boot console on the GB10 UART before the full console driver
  initializes (surfaces early panics).
- `selinux=0` — disabled to keep single-user bring-up simple; revisit for a hardened/multi-tenant target.
