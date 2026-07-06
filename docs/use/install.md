# Install spark-rocky to the NVMe

After you've tried the Live USB ([`running.md`](running.md)) and want to run it for real, you put the stack on
the internal NVMe. There are **two deliberate, repo-run paths — neither is baked into the released image**
(baking a NVMe-wiping installer into a hand-off image is exactly what we don't do; the validation pitch is
*non-destructive*, #34):

| Path | Script | When |
|---|---|---|
| **In-place upgrade (non-destructive)** | `upgrade-metal.sh` | **staying current** on an existing spark-rocky install |
| **Clean install (destructive wipe)** | `install-baremetal.sh` | a **bare disk / clean reinstall** |

## In-place upgrade (non-destructive) — preferred for staying current
On the running metal (which is also the build host), after a successful `01`→`04` build:
```
sudo scripts/upgrade-metal.sh
```
It installs the freshly-built `$KVER` (kernel + modules + open `.ko` + a zstd initramfs) **alongside** the
running kernel, makes it the GRUB default, and **keeps the currently-running kernel as a labeled fallback**.
Your data, docker, and SSH keys are untouched. Reboot; if anything is off, pick the previous kernel at the 5-second
menu. *Validated on the GB10 (2026-07-06): 6.18.37 → 6.18.38 in place — booted, `proof-of-life` CUDA PASS,
fallback retained.*

## Clean install (destructive wipe)
> Boot-from-USB is verified end to end. The NVMe **wipe** install is proven on the reference box but **not yet
> re-run clean-room against the current image** (tracked in #34; the productize-for-others phase is parked). It
> now requires a **typed confirmation** before it touches the disk.

1. **Boot the Spark off the USB** on **wired Ethernet** (the MT7925 WiFi firmware init is unreliable on the
   stock kernel — platform-level; see [`../build/platform-deltas.md`](../build/platform-deltas.md)).
2. **Get `install-baremetal.sh` onto the booted box** (deliberately not baked into the image) and run it:
   ```
   git clone https://github.com/maxspevack/spark-rocky
   sudo spark-rocky/scripts/install-baremetal.sh
   ```
   **DESTRUCTIVE: it wipes the internal NVMe** (DGX OS + all data) — you must type **`WIPE /dev/nvme0n1`**
   exactly to proceed — then rsyncs the proven Rocky onto `/dev/nvme0n1p2` and installs grub (arm64-efi,
   explicit `grub.cfg`, no BLS/shim/os-prober).
3. **Reboot** with the USB removed. The box comes up on the NVMe.

## Verify (either path)
```
/root/proof-of-life.sh
```
Confirms the OS, the kernel (`uname -r` = the pinned kernel), `nvidia-smi` (the GB10 and driver), and a CUDA
`vectorAdd` on the GPU.
