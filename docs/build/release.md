# Release process

How a verified spark-rocky release is cut. The invariant this process exists to protect: **the bytes served == the git tag == the commit that built them.** The failure it prevents is the served image drifting behind the code (a stale, broken image being served while the fixes sit in `main`).

## Cut a release

Run on the Spark (aarch64 — `05` chroots into the image):

1. **Build from HEAD.** `01`→`05` (or `04`+`05` when the kernel, rootfs, and driver are unchanged). The `05` packaging gate is fail-closed: it re-verifies every hardening step against the mounted image and the manifest, and aborts without emitting a checksum if anything is wrong.
2. **SERVE GATE (mandatory since #65/#67).** Put the built kernel on the metal (`upgrade-metal.sh`), reboot to a clean GPU pool, and run:
   ```
   scripts/serve-gate.sh          # brings up the pinned vllm-node, waits for /health 200 + a served model
   ```
   It must print `GATE-PASS`. This exercises the large (~90 GB) KV-cache allocation that `05` and `validate.sh`'s `vectorAdd` do **not** — the exact path the 64k regression ([#65](https://github.com/maxspevack/spark-rocky/issues/65)) faulted on. **A release that has not passed the serve gate on its own kernel is not signable.** `vectorAdd` green is necessary, not sufficient.
3. **Sign**, on the host that holds the release key: `OUTDIR=<vend-dir> scripts/06-sign-release.sh`. Produces the GPG-clearsigned `CHECKSUM` and exports the public key. The passphrase comes from the human via pinentry; it is never scripted.
4. **Tag the build commit:**
   ```
   git tag -f spark-rocky-live-<YYYYMMDD> <commit>
   git push -f origin spark-rocky-live-<YYYYMMDD>
   ```
5. **Upload** the artifacts (`.raw.xz`, the **three rpms** — kernel #59, `kmod-nvidia-open` + `nvidia-driver-userspace` #77, `CHECKSUM`, `BUILD-MANIFEST.txt`, public key) to the release bucket.
6. **Verify, fail-closed:**
   ```
   scripts/07-verify-release.sh spark-rocky-live-<YYYYMMDD>
   ```
   It must print `RELEASE-INTEGRITY: OK` — served commit == tag, Good signature from the release key, and the served image's sha is the one inside the signed CHECKSUM. **Do not announce a release until this is green.**

## The tag's contract

`spark-rocky-live-<YYYYMMDD>` points at the commit that built the served image. `07-verify-release.sh` is its only consumer and its enforcer: `served == tag`. HEAD advancing past the tag is allowed — you can release tag N and keep committing toward N+1 — so `07-verify` treats that as a warning, not a failure. Re-cut and re-tag deliberately when those commits should ship.

## Rollback

Re-point the tag at the prior commit, re-upload the prior artifacts, and run `07-verify-release.sh` against the tag. It confirms the rollback the same way it confirms a release. Minutes, not hours.
