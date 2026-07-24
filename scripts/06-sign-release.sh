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
gpg --list-secret-keys "$KEY" >/dev/null 2>&1 || { echo "FATAL: no secret key matching '$KEY' — mint it first"; exit 1; }

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
