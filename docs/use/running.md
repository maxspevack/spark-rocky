# Run spark-rocky on your DGX Spark

A signed Live USB image runs Rocky Linux 10.2, the stock upstream **6.18.35 kernel with 64k pages** (`uname -r` → `6.18.35`; `getconf PAGESIZE` → `65536`), and the open NVIDIA driver 610.43.02 on the GB10. **Non-destructive: it boots from the USB only; your internal NVMe (DGX OS, models, data) is not mounted or written.** Three steps: flash, boot, check.

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
Reboot and select the USB in the firmware boot menu (or set a one-time boot entry). The image logs in to a root shell automatically.

## 3. Run the check
```
/root/validate.sh
```
It checks the kernel, the open driver, `nvidia-smi`, and a CUDA kernel on the GPU, then prints `PASS` or `FAIL`. Reboot to return to your normal setup.

---
- Verify the release yourself, or read the trust model: [`verify.md`](verify.md).
- Build the image from source instead of downloading it: [`build.md`](../build/build.md).
