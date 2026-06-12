# Write the image to a USB and boot

You don't build anything — write the signed image to a USB-C stick, boot your Spark off it, run one command. ~15 minutes, most of it the download. **Non-destructive:** you boot *from the USB*; your internal NVMe (OS, models, data) is untouched.

## 1. Get the files

Download the release: the image (`spark-rocky-live-*.raw.xz`), `CHECKSUM`, the signing key, and the manifest. During the internal validation phase the link is in your invite; the public release location follows [#29](https://github.com/maxspevack/spark-rocky/issues/29).

## 2. Verify it (recommended)

[`verify.md`](verify.md) — import the key, `gpg --verify CHECKSUM`, `sha256sum -c CHECKSUM`. Two commands; proves the image is authentically ours and your download is intact.

## 3. Write it to a USB-C stick

Use a **reputable USB 3.x stick** — a slow/cheap one can take 5–10× longer.

- **Easiest (GUI):** Raspberry Pi Imager or balenaEtcher — both read `.xz` directly. Point at the file, pick the USB, write.
- **CLI:** `sudo scripts/write-usb.sh spark-rocky-live-*.raw.xz /dev/sdX` (reports the write speed, refuses any non-removable disk), or
  `xz -dc spark-rocky-live-*.raw.xz | sudo dd of=/dev/sdX bs=16M iflag=fullblock oflag=direct status=progress; sync`

## 4. Boot the Spark off the USB

Non-destructive — your NVMe is untouched. Pick the USB from your firmware's boot menu (or set a one-time boot to it). At the console, log in: **`root` / `rocky`**.

- *Headless (no monitor)?* The image allows key-based root SSH but not passwords — before booting, mount the USB's root partition and add your public key to `/root/.ssh/authorized_keys`.

## 5. Validate

Run **`/root/validate.sh`** — it checks the kernel, the open NVIDIA driver, the GPU, and runs a real CUDA kernel, then prints **PASS** or **FAIL**. That's the whole test: PASS means the stack works on your box.
