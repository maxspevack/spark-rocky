# Platform deltas — an unmodified 6.18 tree + open driver on the GB10

What an unmodified 6.18 kernel tree (the shipped **CLK** default or the stock-mainline A/B path — this
repo patches neither) + the open NVIDIA driver surface on the DGX Spark (GB10) at boot, each line
classified and decided. The project starts from a zero-carried-patch clean room; every divergence is a
deliberate, data-justified tweak — **carried** (tracked here + in [`THIRD_PARTY.md`](../../THIRD_PARTY.md)) or
**upstreamed**. The pitch is auditability: every tweak is named and reasoned, not inherited from an opaque
vendor image. (The dmesg census below was recorded on the stock-mainline host; the CLK baseline is in
[`dmesg-baseline.md`](dmesg-baseline.md).)

The load-bearing fact: **GPU compute works** — `proof-of-life` runs `vectorAdd` on the GB10 (compute 12.1,
130.7 GB) on the LiveUSB boot of every shipped release since 6.18.35. (Unit note, once: the unified
memory is 121 GiB ≈ 130 GB decimal — `nvidia-smi` reports decimal GB, other docs say 121 GB binary;
same memory.) Everything below is peripheral to that.

## Page size — 4k today, and the trade that decides it (#65, #80, #81)

**We ship a 4k-page kernel** (`CONFIG_ARM64_4K_PAGES`), pinned as `PAGE_SIZE=4k` in
[`config/versions.env`](../../config/versions.env). Not because 4k is better for this box — it isn't, on the
evidence below — but because of a driver defect that forces a choice.

### The trade, stated plainly: you cannot have both the newest driver and 64k pages

**64 KiB pages and the current NVIDIA driver branches are mutually exclusive on this hardware.** The reason
is a defect we root-caused and reported upstream:
**[NVIDIA/open-gpu-kernel-modules#1269](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1269)**.

| driver branch | EOL | 64 KiB pages |
|---|---|---|
| **580 (LTSB)** — also what DGX OS ships for the GB10 | Jun 2028 | **works** |
| 590 (dropped), 595 (Production), **610 (preview, what we ship)** | Aug 2026 for 610 | **broken** |

`kernel-open/common/inc/nv-linux.h` guards its DMA-submap sizing with `CONFIG_ARM64_4K_PAGES`, but the
invariant that guard implements — *"the mapped IOVA range must be aligned at 2M boundary"*, per NVIDIA's own
comment — is a property of ARM64, not of the OS page size. That symbol appears exactly once in the tree and
the `#else` beside it is the generic x86/RISC-V fallback, so a 64 KiB-page ARM64 kernel inherits a submap
size of `0xFFFF0000` — which is **not** 2 MiB-aligned. Every GPU mapping of 4 GiB or more then contains an
unusable 64 KiB page just below each 4 GiB boundary. `cudaMalloc` *succeeds*; the first read or write to such
a page raises **Xid 31 `FAULT_PTE`** and the process dies. vLLM fails at engine init allocating its KV cache.

The requirement tightened from 64 KiB to 2 MiB alignment in **590.44.01** (2025-12-02) and only the arm with
an explicit constant was updated. Before that, every 64 KiB page count satisfied 64 KiB alignment for free —
which is why the generic branch was adequate and went unrevisited.

**Full investigation, with every measurement and the one-hunk patch:**
[`#65`](https://github.com/maxspevack/spark-rocky/issues/65) is the tracker;
[`#68`](https://github.com/maxspevack/spark-rocky/issues/68) (closed) carries the root-cause record;
the sealed evidence package, per-claim provenance table, minimal reproducer and patch live in the
maintainer's `~/dev/local/68-64k-seam/`.

### How we know it is alignment and not size

Sweeping `NV_DMA_SUBMAP_MAX_PAGES` on one machine, same kernel and driver throughout:

| pages | submap bytes | 2 MiB-aligned | result |
|---|---|---|---|
| 65472 | `0xFFC00000` | yes | pass |
| **65488** | `0xFFD00000` | **no** | **FAULT** |
| 65504 | `0xFFE00000` | yes | pass |
| 65520 | `0xFFF00000` | no | FAULT |
| 65535 (shipping) | `0xFFFF0000` | no | FAULT |

65488 faults while **both** a smaller (65472) and a larger (65504) value pass. The series is non-monotone in
size, so no size threshold explains it. Writing `δ = roundup(S, 2MiB) − S`, the unmapped range is the top `δ`
bytes of each window and is empty when `δ = 0` — which accounts for every offset probed.

### The three ways to have 64k, and what each costs

1. **Driver 580.x (LTSB).** Verified 2026-07-31 on this box: 64 KiB pages + `580.173.02`, stock allocator,
   **no patch and no workaround** — reproducer clean, a 90 GiB allocation clean, and a real vLLM serve
   `GATE-PASS` with a 91.38 GiB KV cache, zero Xid events, `dmesg` err/crit census unchanged from the 610
   baseline. This driver also advertises CUDA 13.0, matching our pinned serving container. **Cost:** it means
   *not* running the newest published driver, and every parity receipt in this repo is anchored on 610, so the
   proof corpus needs re-running. Tracked as [#80](https://github.com/maxspevack/spark-rocky/issues/80).
2. **`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`** on the current driver. PyTorch then maps in 2 MiB
   granules and never reaches a submap boundary. Proven under load. **Cost:** it protects only allocations
   made through PyTorch's caching allocator — anything else requesting ≥ 4 GiB still faults — so it is
   containment for a known workload, not something an appliance can promise its users.
3. **The patch.** One hunk, validated with a there-and-back on stock kernel.org mainline. **Cost:** carrying
   it breaks this project's zero-patch promise, so it is not a shipping option unless NVIDIA takes it.

### Why 64k is worth wanting at all — and why that number is now suspect

The GB10 is a concurrent AI-serving box. 64 KiB pages cut TLB misses and page-table walks under the large
memory working sets this workload lives in. The 2026-06-16 measurement (full 104-cell matrix, 35B-A3B-FP8,
`6.18.35`/64k vs 4k) showed median +2.3%, **35 cells winning ≥ +5% against 3 losses**, clustered on
concurrent and deep-context cells (`tg128@d65535 (c10)` **1.30×**, `ctx_pp@d4096 (c2)` **1.38×**).

**Read that number with the caveat it now carries:** it was taken on a stack containing this defect. The
workload completed only because it never touched one of the poisoned pages. The measurement is not *wrong*,
but the configuration was silently broken, and it is the sole evidence behind a 64k default. Re-measuring on
a correct stack is [#81](https://github.com/maxspevack/spark-rocky/issues/81), and until that lands, 64k's
advantage should be treated as **plausible and unproven**, not established.

### How the pin is enforced (process, not just a flag)

`PAGE_SIZE` is a pinned, reviewable line; `01` sets the `CONFIG_ARM64_4K_PAGES` / `_64K_PAGES` symbol from
it (page size adds **no** uname suffix — source lineage does: `-clk` on the default path); `05`'s
fail-closed gate **aborts the release if the resolved `.config` page size does not match the pin** (the
current `4k` pin cannot ship a 64k image, and vice versa); the provenance stamp records `page_size=4k`; and
the `validate.sh` doctor asserts the running `getconf PAGESIZE` matches what was built. The page size lives
in the `.config` symbol plus the stamp, never in a uname tag — so flipping the pin is a one-line, fully
gated change once the trade above is decided.

Historical note: the 64k default shipped undetected in four releases because release validation only ran
`vectorAdd`, a tiny allocation. The mandatory serve gate that closes that hole is
[#67](https://github.com/maxspevack/spark-rocky/issues/67).

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
| L2 | `GPT: alt header not at end of disk` | **CARRY (assembly), fixed** | `04` relocates the GPT backup header with `sfdisk` after `dd` — fail-closed since #60; the old `sgdisk` path failed open (cosmetic delta; we `dd` a sized image onto a larger stick) |
| L3 | `arm-smmu-v3: PRI will be broken / msi_domain absent` | **BENIGN on current firmware** | Persists at latest firmware; configs are `=y`, so it's the platform ACPI/IORT. The GB10 GPU is NVLink-C2C-coherent (not the PCIe SMMU-SVA path) — compute is unaffected (observed) |
| L4 | `NVDA8800:00 device-creation -16` | **BENIGN, boot-to-boot intermittent** | 1 of ~30 NVDA Grace platform devices; the only one that fails (resource conflict); non-critical to compute. Vanished after the 2026-07-17 firmware update, returned on the 2026-07-23 boot at the same firmware — intermittent at current firmware, not firmware-resolved (see `dmesg-baseline.md`) |
| L5 | `EM: CPUs … same capacity` (×15) | **BENIGN by evidence (closed 2026-07-27)** | Platform ACPI doesn't feed cpu `capacity-dmips-mhz` to the energy model; could in principle change EAS scheduling across X925 vs A725. The proposed before/after quantification is answered by the parity receipts themselves — full-matrix medians 0.96–1.05× vs published (re-proven 1.010× on the current runtime): whatever EAS does with flat capacities, published numbers come back at parity. The related energy-axis measurement closed won't-do (#41: the GB10 exposes no usable CPU-energy counters) |
| L6 | `mt7925` WiFi/BT firmware missing | **FIXED (#64), rpm-pure since 2026-07-23** | `02` dnf-installs the stock Rocky subpackages (`mt7xxx-firmware` + `wireless-regdb`) into the rootfs; `01` enables `FW_LOADER_COMPRESS_ZSTD` so the kernel decompresses el10's compressed blobs at load time. **Correction:** the 2026-07-22 "a `.zst` load fails at the driver's early probe on this platform" was a misdiagnosis — the kernel config simply lacked ZSTD firmware decompression (`_XZ` was on, `_ZSTD` off); nothing platform-specific. The interim hand-decompressed-`.bin` fix worked for that reason and is retired. Wired stays the benchmark default; the radios are *available* (the rpm-pure path metal-verified 2026-07-23 — the dmesg gate: WM firmware loads from the rpm-owned `.xz` at ~6s, `wlP9s9` up, the 3 radio err/crit lines gone). |
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
