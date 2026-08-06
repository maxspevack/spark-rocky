#!/bin/bash
# Sign a built spark-rocky release the way Fedora/Rocky do: write a CHECKSUM over the release
# artifacts, GPG-CLEARSIGN it with the release key, and export the public key. Run AFTER
# 05-package-image.sh, on the box that holds the release private key (the passphrase is supplied
# by the human via gpg-agent/pinentry — never by this script).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${W:-$(dirname "$HERE")}"
OUTDIR="${OUTDIR:-$W/vend}"
KEY="${KEY:-spark-rocky release signing}"     # uid substring of the signing key
cd "$OUTDIR"
shopt -s nullglob
ARTS=( *.raw.xz *.rpm *.BUILD-MANIFEST.txt *.packages.txt )   # *.rpm: kernel + kmod + userspace rpms ride the same signed CHECKSUM (#59/#77)
[ ${#ARTS[@]} -gt 0 ] || { echo "FATAL: no release artifacts in $OUTDIR — run 05 first"; exit 1; }
# ONE release per signing run (review M8): vend-dir rotation is manual, and a leftover second image
# would get an authentic signature — then flash.sh takes the alphabetically-FIRST .raw.xz line from
# the CHECKSUM, i.e. the OLDER image, with a fully valid chain. Refuse ambiguity outright.
IMGS=( *.raw.xz ); MANS=( *.BUILD-MANIFEST.txt )
[ ${#IMGS[@]} -eq 1 ] || { echo "FATAL: ${#IMGS[@]} images in $OUTDIR — one release per vend dir; rotate/clean before signing"; exit 1; }
[ ${#MANS[@]} -eq 1 ] || { echo "FATAL: ${#MANS[@]} manifests in $OUTDIR — one release per vend dir; rotate/clean before signing"; exit 1; }
RPMS=( *.rpm )
[ ${#RPMS[@]} -le 3 ] || { echo "FATAL: ${#RPMS[@]} rpms in $OUTDIR — a release vends at most 3 (kernel, kmod, userspace); a leftover from a prior cut would be signed as part of this release"; exit 1; }
gpg --list-secret-keys "$KEY" >/dev/null 2>&1 || { echo "FATAL: no secret key matching '$KEY' — mint it first"; exit 1; }

# The release gates must be BOUND to the bytes about to be signed, not remembered.
# serve-gate.sh says "a release is not signable until this prints GATE-PASS" and 05b
# is "a mandatory release step (#85)", but nothing enforced either: 05 -> 06 under
# time pressure produced a signature -- the trust anchor of the whole distribution --
# over an image that never served and never booted. Worse, 05b validates the newest
# vend image at gate time, so re-running 05 afterwards (a doc fix, a re-pack) left the
# gate "passed" against bytes that no longer exist. #35's own lesson: a thing a human
# remembered, not a thing a script enforced.
IMG_SHA="$(sha256sum "${IMGS[0]}" | cut -d' ' -f1)"
require_receipt() {
    local file="$OUTDIR/$1" label="$2" hint="$3"
    [ -f "$file" ] || {
        echo "FATAL: no $label receipt in $OUTDIR."
        echo "       $hint"
        echo "       (override for a deliberately ungated signature: ALLOW_UNGATED=1)"
        exit 1
    }
    grep -qx "$IMG_SHA" "$file" || {
        echo "FATAL: the $label receipt does not cover ${IMGS[0]}."
        echo "       receipt: $(head -1 "$file" 2>/dev/null)"
        echo "       image:   $IMG_SHA"
        echo "       The image was re-packaged after the gate ran. Re-run the gate."
        exit 1
    }
    echo "  ok: $label receipt covers this image"
}
if [ "${ALLOW_UNGATED:-0}" = 1 ]; then
    echo "WARNING: ALLOW_UNGATED=1 — signing WITHOUT serve-gate/boot-gate receipts."
else
    echo "=== release gates (must cover ${IMG_SHA:0:12}) ==="
    require_receipt serve-gate.pass "serve-gate" \
        "Run scripts/serve-gate.sh on the box, on the kernel being released."
    require_receipt boot-gate.pass "boot-gate (05b)" \
        "Run BOOT_GATE_HOST=<host> scripts/05b-boot-gate.sh to boot the artifact."
fi

echo "=== CHECKSUM over: ${ARTS[*]} ==="
CK="CHECKSUM"
sha256sum "${ARTS[@]}" > "$CK.plain"
cat "$CK.plain"

echo "=== clearsign into ONE authoritative CHECKSUM (Fedora model; no unsigned duplicate to swap) ==="
rm -f "$CK"
gpg --default-key "$KEY" --clearsign --output "$CK" "$CK.plain"
rm -f "$CK.plain"
gpg --verify "$CK" 2>&1 | sed 's/^/  /' && echo "  clearsigned CHECKSUM verifies OK"

echo "=== export public key (publish in the repo + beside the image) ==="
PUB="spark-rocky-release-key.asc"
gpg --armor --export "$KEY" > "$PUB"
FPR=$(gpg --with-colons --fingerprint "$KEY" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')

echo ""
echo "=== SIGNED RELEASE ==="
ls -lh "$CK" "$PUB" "${ARTS[@]}"
echo "fingerprint: $FPR"
echo "Publish $PUB + this fingerprint in docs/use/verify.md; share the fingerprint OUT-OF-BAND (not only in-repo)."
