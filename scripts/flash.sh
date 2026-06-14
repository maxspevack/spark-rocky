#!/bin/bash
# Fetch the signed spark-rocky release, verify it, and write it to a USB stick. One command, fail-closed
# at every step: the CHECKSUM signature must come from the PINNED key fingerprint (not merely "a" key),
# the image sha must match, and the write goes through the guarded writer that refuses a non-USB disk.
#
# Usage: sudo scripts/flash.sh <usb-device> [base-url]
#   <usb-device>  target stick, e.g. /dev/sdX on Linux. Find it with `lsblk`; match by SIZE and MODEL.
#   [base-url]    release location, e.g. https://storage.googleapis.com/spark-rocky
#                 Omit to read RELEASE_BASE_URL from config/release.env.
#
# The release URL is gated until public launch (#12) and is intentionally NOT committed. Internal
# validators: take it from your validation invite and pass it as arg 2 (or set it in config/release.env
# locally, uncommitted). Downloads land in the current directory and are reused on re-run; override
# with FLASH_DLDIR=.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FPR="71C16676F9D40A4CE0C6EB6608B14BC398311101"   # pinned release-signing fingerprint; confirm out of band

DEV="${1:-}"; BASE="${2:-}"
[ -n "$BASE" ] || BASE="$(. "$HERE/../config/release.env" 2>/dev/null; printf '%s' "${RELEASE_BASE_URL:-}")"
[ -n "$DEV" ]  || { echo "usage: sudo $0 <usb-device> [base-url]"; exit 2; }
[ -n "$BASE" ] || { echo "FATAL: no release URL. Pass it as arg 2, or set RELEASE_BASE_URL in config/release.env (get it from your validation invite)."; exit 2; }
[ "$(id -u)" = 0 ] || { echo "FATAL: must run as root (it writes a block device): sudo $0 $*"; exit 2; }
for t in curl gpg sha256sum xz; do command -v "$t" >/dev/null || { echo "FATAL: missing required tool: $t"; exit 2; }; done

DL="${FLASH_DLDIR:-$PWD}"; mkdir -p "$DL"; cd "$DL"
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; trap 'rm -rf "$GNUPGHOME"' EXIT   # throwaway keyring; never touch the user's

echo "=== fetch signed metadata from $BASE ==="
curl -fLsS -o CHECKSUM                    "$BASE/CHECKSUM"                     || { echo "FATAL: cannot fetch CHECKSUM from $BASE"; exit 1; }
curl -fLsS -o spark-rocky-release-key.asc "$BASE/spark-rocky-release-key.asc" || { echo "FATAL: cannot fetch the signing key"; exit 1; }
IMG="$(awk '/\.raw\.xz/{print $2; exit}' CHECKSUM)"
[ -n "$IMG" ] || { echo "FATAL: CHECKSUM names no .raw.xz image"; exit 1; }

echo "=== verify the CHECKSUM signature is from the pinned key ($FPR) ==="
gpg --batch --import spark-rocky-release-key.asc >/dev/null 2>&1 || { echo "FATAL: signing-key import failed"; exit 1; }
gpg --batch --status-fd=1 --verify CHECKSUM 2>/dev/null | grep -q "VALIDSIG $FPR" \
  || { echo "FATAL: CHECKSUM is not signed by the pinned fingerprint $FPR. Refusing — do not write this image."; exit 1; }
echo "  ok: Good signature from $FPR"

# Verify ONLY the image against its line in CHECKSUM. A whole-file `sha256sum -c CHECKSUM` would also try
# the manifest (which flash.sh does not fetch); under `set -o pipefail` that non-zero exit masks a good
# image as a failure. So pull the expected sha and compare it directly.
EXPECT="$(awk -v f="$IMG" '$2==f{print $1; exit}' CHECKSUM)"
[ -n "$EXPECT" ] || { echo "FATAL: CHECKSUM has no sha256 line for $IMG"; exit 1; }
img_ok(){ [ -f "$IMG" ] && [ "$(sha256sum "$IMG" 2>/dev/null | cut -d' ' -f1)" = "$EXPECT" ]; }
echo "=== fetch + verify the image: $IMG ==="
if img_ok; then
  echo "  ok: $IMG already present and verified, reusing"
else
  curl -fLsS -o "$IMG" "$BASE/$IMG" || { echo "FATAL: cannot fetch $IMG"; exit 1; }
  img_ok || { echo "FATAL: $IMG sha256 does not match the signed CHECKSUM. Refusing."; exit 1; }
  echo "  ok: $IMG sha256 verified"
fi

echo "=== write to $DEV (guarded: refuses any non-USB disk) ==="
"$HERE/write-usb.sh" "$DL/$IMG" "$DEV"
