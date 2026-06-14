# Platform deltas — stock-mainline + open driver on the GB10

What a stock upstream kernel + the open NVIDIA driver surface on the DGX Spark (GB10) at boot, each line
classified and decided. The project starts from a zero-source-patch clean room; every divergence is a
deliberate, data-justified tweak — **carried** (tracked here + in [`THIRD_PARTY.md`](third-party.md)) or
**upstreamed**. The pitch is auditability: every tweak is named and reasoned, not inherited from an opaque
vendor image.

The load-bearing fact: **GPU compute works** — `proof-of-life` runs `vectorAdd` on the GB10 (compute 12.1,
130.7 GB) on the LiveUSB boot of 6.18.35. Everything below is peripheral to that.

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
lvfs && fwupdmgr refresh && fwupdmgr upgrade`). As of 2026-06-11 this box is on the **latest published**: UEFI
`0x0200980f` (2026-04-02), EC `0x03000302`, USB-C PD `0x00000516`, confirmed against LVFS (stable + testing) and
NVIDIA's release notes. GPU VBIOS `9A.0B.25.00.00` and GSP `610.43.02` ride the driver and are current with it.
**Consequence:** parity benchmarks run on the same latest firmware a DGX OS box runs — no firmware confound.

## Ledger
| ID | Delta (dmesg) | Decision | Notes |
|----|---------------|----------|-------|
| L1 | open driver didn't auto-load → `nvidia-smi` failed | **CARRY (assembly), fixed** | `02b` now runs `depmod` + writes `/etc/modules-load.d/nvidia.conf`; build gates assert nvidia is in `modules.dep` |
| L2 | `GPT: alt header not at end of disk` | **CARRY (assembly), fixed** | `04` runs `sgdisk -e` after `dd` (cosmetic; we `dd` a sized image onto a larger stick) |
| L3 | `arm-smmu-v3: PRI will be broken / msi_domain absent` | **BENIGN on current firmware** | Persists at latest firmware; configs are `=y`, so it's the platform ACPI/IORT. The GB10 GPU is NVLink-C2C-coherent (not the PCIe SMMU-SVA path) — compute is unaffected (observed) |
| L4 | `NVDA8800:00 device-creation -16` | **BENIGN on current firmware** | 1 of ~30 NVDA Grace platform devices; the only one that fails (resource conflict); non-critical to compute |
| L5 | `EM: CPUs … same capacity` (×15) | **MEASURE** | Platform ACPI doesn't feed cpu `capacity-dmips-mhz` to the energy model; may change EAS scheduling across X925 vs A725 → possible perf. Quantify with a before/after spark-arena run |
| L6 | `mt7925` WiFi/BT firmware missing | **DECLINE, with reason** | Wired-only is more deterministic for a benchmark box; thesis-safe to add `linux-firmware` later if WiFi is wanted |
| L7 | `mlx5` ConnectX-7 floods dmesg (missing firmware; "insufficient power" → down) | **CARRY (assembly), fixed** | The ConnectX is the cluster-fabric port; multi-node is out of scope, so `04` blacklists `mlx5_core` (rootfs + dracut initramfs). Not loading the unused driver removes the flood (#30). Re-enable + ship the mlx5 firmware if you ever cable it for clustering |
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
- `quiet loglevel=3` — trims the boot console to essentials; paired with `modeset=0` the boot is clean, not a wall
  of warnings.
- `earlycon=uart,mmio32,0x16A00000` — early-boot console on the GB10 UART before the full console driver
  initializes (surfaces early panics).
- `selinux=0` — disabled to keep single-user bring-up simple; revisit for a hardened/multi-tenant target.
