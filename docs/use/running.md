# Run spark-rocky on your DGX Spark

A signed Live USB image runs Rocky Linux 10.2, the **CIQ Linux Kernel — CLK 6.18 with 4k pages** (`uname -r` → `6.18.42-clk`, the suffix states the kernel lineage; `getconf PAGESIZE` → `4096`), and the open NVIDIA driver 610.57.04 on the GB10. **Non-destructive: it boots from the USB only; your internal NVMe (DGX OS, models, data) is not mounted or written.** Three steps: flash, boot, check.

You need an 8 GB or larger USB stick (the image is 6 GB uncompressed) and a Linux or macOS host to write it.

## 1. Flash the stick (one command)
```
git clone https://github.com/maxspevack/spark-rocky && cd spark-rocky
sudo scripts/flash.sh /dev/sdX
```
`/dev/sdX` is the USB stick; find it with `lsblk` (Linux) or `diskutil list` (macOS) and match it by size and model. `flash.sh` reads the release location from `config/release.env`.

`flash.sh` downloads the release, verifies the GPG signature against the pinned key fingerprint and the sha256 (fail-closed at each step), then writes it through the guarded writer, which refuses any disk that is not a removable USB.

**No command line?** Download the release files from the URL, verify them ([`verify.md`](verify.md)), then write the `.raw.xz` with balenaEtcher or Raspberry Pi Imager — both read `.xz` directly and will not let you select an internal disk.

## 2. Boot the Spark from the USB
**Secure Boot must be disabled** (UEFI setup → Secure Boot → Disabled). The kernel in this image is a
custom, unsigned build — with Secure Boot enabled the firmware/shim chain will refuse it and the stick
simply won't boot. The DGX Spark we validate on reports `SecureBoot disabled` (setup mode, no platform
key enrolled). This is a deliberate, documented posture, not an oversight: the trust anchor of a
spark-rocky release is the **GPG-signed artifact you verified in step 1** (what lands on the stick is
provably the released bytes); what you give up is boot-*chain* attestation at power-on. If your
threat model requires Secure Boot, this image is not for you as shipped — see the boot-chain note in
[`build.md`](../build/build.md).

Reboot and select the USB in the firmware boot menu (or set a one-time boot entry). The image
logs in to a root shell automatically (behavior-gated in `validate.sh` §7 since #97 — verified
2026-08-11 on the GB10 metal, which runs the same drop-in the bake writes; §7 makes every future
image boot prove it).

## 3. Run the check
The console auto-logs-in as root. If it ever does not, the console credential is **`root` /
`rocky`** — console-only: the image ships with network password auth disabled (key-only SSH).
```
/root/validate.sh
```
It checks the kernel, the open driver, `nvidia-smi`, and a CUDA kernel on the GPU, then prints `PASS` or `FAIL`. Reboot to return to your normal setup.

---
- Verify the release yourself, or read the trust model: [`verify.md`](verify.md).
- Build the image from source instead of downloading it: [`build.md`](../build/build.md).
