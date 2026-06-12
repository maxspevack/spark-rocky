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
ARTS=( *.raw.xz *.BUILD-MANIFEST.txt *.packages.txt )
[ ${#ARTS[@]} -gt 0 ] || { echo "FATAL: no release artifacts in $OUTDIR — run 05 first"; exit 1; }
gpg --list-secret-keys "$KEY" >/dev/null 2>&1 || { echo "FATAL: no secret key matching '$KEY' — mint it first"; exit 1; }

echo "=== CHECKSUM over: ${ARTS[*]} ==="
CK="CHECKSUM"
sha256sum "${ARTS[@]}" > "$CK"
cat "$CK"

echo "=== GPG-clearsign the CHECKSUM ==="
rm -f "$CK.asc"
gpg --default-key "$KEY" --clearsign --output "$CK.asc" "$CK"
gpg --verify "$CK.asc" 2>&1 | sed 's/^/  /' && echo "  clearsign round-trips OK"

echo "=== export public key (publish in the repo + beside the image) ==="
PUB="spark-rocky-release-key.asc"
gpg --armor --export "$KEY" > "$PUB"
FPR=$(gpg --with-colons --fingerprint "$KEY" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')

echo ""
echo "=== SIGNED RELEASE ==="
ls -lh "$CK" "$CK.asc" "$PUB" "${ARTS[@]}"
echo "fingerprint: $FPR"
echo "Publish $PUB + this fingerprint in docs/verify.md; share the fingerprint OUT-OF-BAND (not only in-repo)."
