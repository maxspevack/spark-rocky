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

## Page size — 64k is the destination, 4k is what ships, and a gate holds the line (#65, #80, #81)

**The committed direction is 64 KiB pages.** That is settled for this box and not reopened by benchmarking.
**What ships today is a 4k-page kernel** (`CONFIG_ARM64_4K_PAGES`, pinned `PAGE_SIZE=4k` in
[`config/versions.env`](../../config/versions.env)) — not because 4k is better here, but because 64k is
*incorrect* on the driver we ship, and shipping a knowingly-faulting appliance is not a trade we will make.

**What makes that a lock-in rather than an intention: a fail-closed gate.** `config/versions.env` declares
`DRIVER_64K_SAFE` — the driver versions *proven* correct under 64k on this hardware — and `05` refuses to
package a 64k image on any driver not on that list. The shipping driver (`610.57.04`, like `610.43.03` before it) is deliberately absent.
So the day [#1269](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1269) lands, the entire change is
**two reviewable lines** — add the fixed version to `DRIVER_64K_SAFE`, flip `PAGE_SIZE=64k` — and the gate,
not a promise in a document, is what proves the flip is safe. Flip the pin today and the release aborts at
packaging. That is the mechanism working.

### The trade, stated plainly: you cannot have both the newest driver and 64k pages

**64 KiB pages and the current NVIDIA driver branches are mutually exclusive on this hardware.** The reason
is a defect we root-caused and reported upstream:
**[NVIDIA/open-gpu-kernel-modules#1269](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1269)**.

| driver branch | support commitment | 64 KiB pages | relative perf (4k, measured 2026-07-31) |
|---|---|---|---|
| **580 (LTSB)** — also what DGX OS ships for the GB10 | ~3 yr per lifecycle policy; **no published per-branch date** | **works** | **0.896× — 10.4% slower** |
| 590 (dropped), 595 (Production), **610 (New Feature Branch, what we ship)** | none for 610 — NFBs have no formal support period (NVIDIA lifecycle policy; 610.57.04 released 2026-08-03) | **broken** | 1.000× (baseline) |

So the two properties we want are on opposite branches, and the branch that gives correctness under 64k costs
about 10% throughput. That is the whole trade, and it is why we ship 4k on 610.

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

### The three ways to have 64k — one is now closed on evidence

1. **~~Driver 580.x (LTSB)~~ — REJECTED 2026-07-31, on measurement.** 64 KiB pages *do* work on 580: verified
   on this box with `580.173.02`, stock allocator, no patch and no workaround — reproducer clean, a 90 GiB
   allocation clean, a real vLLM serve `GATE-PASS` with a 91.38 GiB KV cache, zero Xid events. **But the driver
   itself is ~10% slower.** A driver-only A/B with the page size held at 4k, same box / kernel / pinned
   serving image / recipe / script, 104 cells each side:

   | measured 2026-07-31 | 580.173.02 vs 610.43.03 |
   |---|---|
   | full-matrix median | **0.896 — 10.4% slower** |
   | decode (`tg*`, n=28) | 0.911 — 8.9% slower |
   | prefill (`pp`/`ctx`, n=76) | 0.894 — 10.6% slower |
   | cells >5% slower on 580 | **94 / 104** |
   | cells >5% faster on 580 | **0 / 104** |

   Throttle-CLEAN on both legs, so this is not thermal. `tg128 (c1)` 124.09 → 113.65; `pp2048 (c1)`
   22317 → 17299 (−22.5%); worst cell 0.636×. Receipt:
   [`reproduce-Qwen3.5-0.8B-driver-AB-580-vs-610-2026-07-31.txt`](../../receipts/reproduce-Qwen3.5-0.8B-driver-AB-580-vs-610-2026-07-31.txt).

   **The arithmetic that closes it:** 64k's best-case gain is a median **+2.3%** (and that was measured on a
   stack carrying this very defect). 580's cost to obtain 64k is a median **−10.4%**. Trading ~8 points of
   median throughput for a 2.3% page-size win is a net loss by a wide margin. *Honest limit:* one model
   (Qwen3.5-0.8B), one matrix — but 94 of 104 cells slower with zero winners makes a reversal unlikely.

2. **`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`** on the current driver — **the only live candidate.**
   PyTorch then maps in 2 MiB granules and never reaches a submap boundary; proven under load (20/20
   completions, 8k context, 8-way concurrency, zero Xid). **Costs:** it protects only allocations made through
   PyTorch's caching allocator — anything else requesting ≥ 4 GiB still faults — so it is containment for a
   known workload, not something an appliance can promise its users. **Its overhead is now measured and it is
   free:** a 104-cell A/B at 4k against the default allocator, both legs throttle-CLEAN, lands median
   **0.999×** (decode 1.002×, prefill 0.996×, 8 cells faster / 7 slower) — 2026-07-31,
   [#81](https://github.com/maxspevack/spark-rocky/issues/81). So this is the right thing to *recommend* to
   PyTorch users running 64k, and still not a thing to *default* to for everyone.

3. **The patch.** One hunk, validated with a there-and-back on stock kernel.org mainline. **Cost:** carrying it
   breaks this project's zero-patch promise, so it is not a shipping option unless NVIDIA takes it.

**Consequence: [NVIDIA/open-gpu-kernel-modules#1269](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1269)
is now the real gate on 64k**, not a nice-to-have. With the 580 fallback priced and rejected, there is no route
to 64k that is simultaneously correct, fast, patch-free and workload-agnostic until that fix ships.

### Why 64k is worth wanting at all — and why that number is now suspect

The GB10 is a concurrent AI-serving box. 64 KiB pages cut TLB misses and page-table walks under the large
memory working sets this workload lives in. The 2026-06-16 measurement (full 104-cell matrix, 35B-A3B-FP8,
`6.18.35`/64k vs 4k) showed median +2.3%, **35 cells winning ≥ +5% against 3 losses**, clustered on
concurrent and deep-context cells (`tg128@d65535 (c10)` **1.30×**, `ctx_pp@d4096 (c2)` **1.38×**).

**Read that number with the caveat it now carries:** it was taken on a stack containing this defect. The
workload completed only because it never touched one of the poisoned pages. The measurement is not *wrong*,
but the configuration was silently broken, and it is the sole evidence behind a 64k default.

**The re-measure was attempted on 2026-07-31 and has no result yet.** A 64k leg on a correct-by-workaround
stack (`expandable_segments`, driver 610.43.03) ran the full matrix but **throttled** — 4 slowdown samples,
−2 °C T.Limit headroom, 87 °C peak — so the [#43](https://github.com/maxspevack/spark-rocky/issues/43) gate
**discarded it rather than report it**. Sustained 104-cell sweeps saturate this box's cooling; the redo needs
the chunked cool-to-≤55 °C protocol from [`scoreboard.md`](../benchmark/scoreboard.md) chapter 3.
[#81](https://github.com/maxspevack/spark-rocky/issues/81) tracks it. Until then 64k's *magnitude* is
**plausible and unproven**; the *direction* is a settled opinion, and the gate above is how it stays honest.

### How the pin is enforced (process, not just a flag)

`PAGE_SIZE` is a pinned, reviewable line; `01` sets the `CONFIG_ARM64_4K_PAGES` / `_64K_PAGES` symbol from
it (page size adds **no** uname suffix — source lineage does: `-clk` on the default path); `05`'s
fail-closed gate **aborts the release if the resolved `.config` page size does not match the pin** (the
current `4k` pin cannot ship a 64k image, and vice versa); the provenance stamp records `page_size=4k`; and
the `validate.sh` doctor asserts the running `getconf PAGESIZE` matches what was built. The page size lives
in the `.config` symbol plus the stamp, never in a uname tag.

**Two gates, not one.** The *consistency* gate above proves the image matches the pin. The **correctness**
gate added 2026-07-31 proves the pin is safe to ship: if `PAGE_SIZE=64k`, `05` requires `DRIVER_VER` to
appear in `DRIVER_64K_SAFE`, and aborts otherwise. Verified on all three real combinations —
`4k`/`610.43.03` packages, `64k`/`610.43.03` **refuses**, `64k`/`580.173.02` packages. Four `make test`
invariants hold the gate in place, including one that fails if the shipping driver is ever added to the safe
list without earning it. A driver earns a place there only by passing a ≥ 4 GiB allocation test on this
hardware.

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
capsule-on-disk with stock `fwupd`, `fwupdmgr get-updates` clean after. GPU VBIOS `9A.0B.25.00.00` and the GSP
firmware ride the driver (`610.57.04` as of 2026-08-05) and are current with it.
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
