# dmesg err/crit baseline (GB10, 6.18.37)

A durable census of the kernel `err`/`crit` lines a healthy spark-rocky box emits at boot, each root-caused
and marked benign, so a future build's `dmesg -t -l err,crit,alert,emerg` can be diffed against this instead
of re-litigated. **None of these affect the GPU/CUDA path** (proof-of-life passes). Captured 2026-06-29 on the
GB10 booting the 6.18.37 image.

## The baseline (benign — GB10 platform + minimal-image artifacts)

| Line (timestamp-stripped) | Count | Root cause | Verdict |
|---|---|---|---|
| `PCI: OF: of_root node is NULL, cannot create PCI host bridge node` | 8 | ACPI-described platform has no device-tree (OF) root; the PCI layer notes its absence. | benign — SBSA/ACPI constant |
| `platform NVDA8800:00: failed to claim resource 0: [mem 0x05170000-0x051cffff]` | 1 | An NVIDIA ACPI platform-device memory region is already claimed (EBUSY). | benign — GPU works regardless |
| `acpi NVDA8800:00: platform device creation failed: -16` | 1 | Same NVDA8800 device, `-EBUSY` from the above. | benign |
| `ARM FF-A: failed to register FFA RxTx buffers` | 1 | Arm Firmware-Framework (secure-world) RxTx setup; FF-A unused here. | benign |
| `cma: __cma_alloc: reserved: alloc failed, req-size: {256,128} pages, ret: -16` | 2 | Contiguous-memory-allocator reservation retries at boot; allocator falls back. | benign |
| `processor cpuN: EM: CPUs of 0-4,10-14 must have the same capacity` | 10 | Energy Model building domains over the heterogeneous Grace cores (10× Cortex-X925 + 10× Cortex-A725). | benign — correct for a big.LITTLE SoC |
| `processor cpuN: EM: CPUs of 15-19 must have the same capacity` | 5 | Same, the second capacity group. | benign |

These are platform-firmware / ACPI / CPU-topology artifacts we do not own. "Fixing" them would mean carrying
kernel patches (violates the zero-carried-patches thesis) or lying to the scheduler about the topology. We
leave them, by design.

## 6.18.35 → 6.18.37 baseline diff (the stay-current gate, 2026-06-29)

Diffed the running 6.18.35-64k metal's `err/crit` set against the 6.18.37 image's. **Identical except three
lines present on 6.18.37 and absent on the 6.18.35 metal:**

```
Bluetooth: hci0: Failed to load firmware file (-2)
Bluetooth: hci0: Failed to set up firmware (-2)
mt7925e 0009:01:00.0: hardware init failed
```

**These are NOT a 6.18.37 kernel regression.** Root cause, verified by inspecting both rootfs trees:

- The 6.18.35 metal carries `linux-firmware-20260411` (monolithic), which **includes** the MediaTek WiFi/BT
  firmware (`/lib/firmware/mediatek/mt7925`), so the onboard MT7925 radios init silently.
- The fresh 6.18.37 image carries `linux-firmware-20260609`, by which point Rocky had **split `linux-firmware`
  into per-vendor subpackages** (`amd/intel/nvidia-gpu-firmware`, etc.). The MediaTek firmware moved into a
  subpackage that, as a *weak* dependency, is excluded by `02-build-rootfs.sh`'s `--setopt=install_weak_deps=False`.
  So the image ships no MT7925 firmware, and the radios log firmware-missing.

A 6.18.35 rootfs rebuilt with today's packages would show the same three lines — the delta is the userspace
firmware-packaging split, not the kernel. The MT7925 WiFi/BT radios are **unused** (the box is wired:
`r8169`/`enP7s7`), so the lines are benign and the image is in fact more minimal. Optionally silencing them by
blacklisting the unused radios is tracked separately (it needs the `mt7925e` + `btmtk` levers and does not gate
a release).

**Gate result: PASS** — `err/crit(6.18.37) ⊆ err/crit(6.18.35)` plus three explained, benign firmware lines;
the mlx5 missing-firmware flood (#30/#40) is absent on both.
