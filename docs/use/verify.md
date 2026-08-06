# Verify a spark-rocky release

Every spark-rocky live image ships with a GPG-clearsigned `CHECKSUM`. Verifying is three commands and proves two separate things: the checksums are authentically ours (the signature), and your download matches them (the hash). The signing key is published **here in the repo** — a different channel from the image — and its fingerprint should be confirmed **out-of-band** (ask the maintainer directly). An attacker who controls one channel must not control both.

## The signing key

- File: [`keys/spark-rocky-release-key.asc`](../../keys/spark-rocky-release-key.asc) (repo root)
- Fingerprint: `71C1 6676 F9D4 0A4C E0C6  EB66 08B1 4BC3 9831 1101`
- UID: `spark-rocky release signing <max.spevack@gmail.com>`

Confirm that fingerprint through a second channel before trusting it.

## Verify, then write

From the directory holding the release files (`CHECKSUM`, the `.raw.xz`, `BUILD-MANIFEST.txt`):

```
# 1. import the key from THIS repo (not from beside the image); confirm the fingerprint out-of-band.
#    keys/ is repo-relative — from the release-files directory, point at your clone:
gpg --import /path/to/spark-rocky/keys/spark-rocky-release-key.asc

# 2. extract the SIGNED BODY and check the signature in one step
#    gpg reports a good signature on a clearsigned file even when unsigned text
#    has been PREPENDED to it, so always verify against the extracted plaintext
#    -- never against the container you downloaded.
gpg --output CHECKSUM.signed --decrypt CHECKSUM   # must print: Good signature ... 71C1 6676 ...

# 3. your download matches the signed checksums
sha256sum -c CHECKSUM.signed    # the .raw.xz line must say OK
```

`CHECKSUM.signed` holds only the checksum lines that were actually inside the
signature, so step 3 is clean — no armor lines, no "improperly formatted"
warning to wave away, and nothing an attacker appended outside the signed body.

Then flash it and boot: [`running.md`](running.md). After boot, run `/root/validate.sh`.

## Don't trust a pre-built image at all?

Then don't use one — rebuild the whole thing from source and compare. Everything that produced the image is in this repo: `scripts/01`→`07`, `config/`, and the pinned versions in `config/versions.env`. The build is reproducible-in-principle (same commit + same pins → an equivalent image — not bit-for-bit, since `xz -T0` and live `dnf` repos vary). Each image's `BUILD-MANIFEST.txt` records the exact commit, kernel, driver, and `.config` identity so you can tie a download back to a repo state.

## Where the release lives

The release lives at the public location pinned in [`config/release.env`](../../config/release.env) — `flash.sh` reads it automatically, no validator hand-off. (A public *currency commitment* — promising to track upstream within a stated window — is deliberately **not made**: decided 2026-06-29, [#29](https://github.com/maxspevack/spark-rocky/issues/29) closed. Releases stay best-effort, soft-launched, unsupported.)
