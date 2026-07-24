# Debug access strategy

The vended image is **locked by default**: no `authorized_keys`, `PasswordAuthentication no`, root SSH key-only (`prohibit-password`). Nobody — not even the maintainer — can SSH in unless access is explicitly granted. That's deliberate; a vended image shouldn't trust anyone.

But debugging has to be **easy**, or a stuck test user just gives up. So there are two paths, both using a **dedicated** debug key (`config/debug-authorized_keys`, public; the private key is the maintainer's, off-repo, and is *not* a personal key).

## For the test user — the happy path needs nothing

Boot the USB → it **auto-logs-in to a root shell** (no typing) → run `validate.sh` → file the result. No SSH, no keys, no passwords. That's the whole experience.

## For the test user — if something breaks and we need to look

**Run one line** (we'll give it to you in the issue):

```
bash /root/spark-rocky-debug-enable.sh
```

It authorizes the maintainer's dedicated debug key and prints what to do next (tell us the box's IP). Then we SSH in and debug. Undo any time: `rm /root/.ssh/authorized_keys`. That's it — one command, no key to type. The image stays locked until you choose to run it.

## For the maintainer — debugging our own builds

Build with `DEBUG=1`:

```
DEBUG=1 scripts/04-build-image.sh     # injects the dedicated debug key + an /etc/spark-rocky-debug-hatch marker
```

The debug key is baked in, so we SSH straight into our own test boots. **The marker makes the image un-releasable:** `05-package-image.sh` aborts (no checksum, no signature) if `/etc/spark-rocky-debug-hatch` is present and `DEBUG` isn't explicitly set — a debug build can never be signed and shipped as a release by accident.

## The key

- `config/debug-authorized_keys` — public keys only, one per authorized debugger. Safe to commit.
- The matching **private** keys live with each debugger (the maintainer's is in `~/.ssh`, generated for this purpose, **not** a personal key). No shared private key.
- **Revoke** by deleting a line and rebuilding. No PKI, no CA — right-sized for one maintainer + a handful of validators.

## Shipping posture (decided 2026-06-29)

The release posture is soft-launched and unsupported with no broadcast (#29 closed 2026-06-29), and the
hatch **ships as-is**: a documented maintainer opt-in, locked by default, with the un-releasable-DEBUG-build
gate in `05` holding regardless. Revisit only if the broadcast posture ever changes — the question then is
whether the convenience opt-in ships to strangers, and this section is where that decision gets recorded.
