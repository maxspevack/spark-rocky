# Install spark-rocky to the NVMe

After you've tried the Live USB ([`running.md`](running.md)) and decided to run it for real, this lays the stack down on the internal NVMe. **Optional and destructive** — booting the USB never touches your disk; installing replaces what is on it.

> **Not yet clean-room-validated.** The boot-from-USB path is verified end to end. The NVMe install is proven on the reference box but has not been re-run from a clean checkout, and it has no typed-confirmation guard yet (tracked in #34). Read the steps before you run it.

1. **Boot the Spark off the USB** on **wired Ethernet** — the MT7925 WiFi firmware init is unreliable on the stock kernel (platform-level, see [`../build/platform-deltas.md`](../build/platform-deltas.md), L6).
2. **Get `install-baremetal.sh` onto the booted box** (it is deliberately not baked into the image) and run it:
   ```
   git clone https://github.com/maxspevack/spark-rocky
   sudo spark-rocky/scripts/install-baremetal.sh
   ```
   **DESTRUCTIVE: it wipes the internal NVMe** (DGX OS and all data), rsyncs the proven Rocky onto `/dev/nvme0n1p2`, and installs grub (arm64-efi, explicit `grub.cfg`, no BLS/shim/os-prober).
3. **Reboot** with the USB removed. The box comes up on the NVMe.

## Verify
```
/root/proof-of-life.sh
```
Confirms the OS, the kernel (`uname -r` = the pinned kernel), `nvidia-smi` (the GB10 and driver), and a CUDA `vectorAdd` on the GPU.
