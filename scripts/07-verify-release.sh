#!/bin/bash
# Release-integrity gate (#35). The drift that shipped a stale image happened because "served == tag ==
# the commit that built it" was a thing a human remembered, not a thing a script enforced. This is the
# script. Run it as the LAST release step (after upload + tag) and any time on demand.
#
# Durable invariant, FAIL-CLOSED: served bytes == tag, the served CHECKSUM verifies, and the served
# image's sha is the one inside the signed CHECKSUM. HEAD having advanced past the tag is a LOUD WARNING,
# not a failure — you may legitimately release tag N and keep committing toward N+1; the warning just
# makes you re-cut deliberately instead of drifting silently.
#
# Usage: scripts/07-verify-release.sh <release-tag>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:?usage: $0 <release-tag>}"
BUCKET="${BUCKET:-gs://spark-rocky}"
ACCT="${GCLOUD_ACCOUNT:-max.spevack@gmail.com}"   # the bucket lives under the personal account (laptop default is max@ciq.com -> 403)
KEY="${KEY:-$HERE/../keys/spark-rocky-release-key.asc}"
GS="gcloud storage"; A="--account=$ACCT"
fail=0; say(){ printf '%s\n' "$*"; }
# res: report a check's already-computed result. NO eval, deliberately (review M9): every value this
# script compares is parsed from the SERVED manifest — the artifact it exists to distrust — and data
# that crossed a trust boundary must never pass through eval on the verifying machine.
res(){ if [ "$1" = 0 ]; then say "  ok: $2"; else say "  VERIFY-FAIL: $2"; fail=1; fi; }

tagc=$(git rev-list -n1 "$TAG" 2>/dev/null) || { say "FATAL: tag '$TAG' not found locally"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

say "=== fetch served release metadata from $BUCKET ==="
# The manifest object is derived from the tag's release suffix so a superseded sibling can never
# shadow it (#78: at the 20260724 cut a bare *BUILD-MANIFEST.txt wildcard concatenated the stale
# 20260723 manifest and produced four VERIFY-FAILs against a correctly-served release). Exactly one
# match is required — more means the bucket still holds a superseded pair; fail loudly, name them.
rsuffix="${TAG##*-}"
mans=$($GS ls "$BUCKET/*-${rsuffix}.BUILD-MANIFEST.txt" $A 2>/dev/null)
nman=$(printf '%s\n' "$mans" | grep -c .)
if [ "$nman" != 1 ]; then
  say "FATAL: expected exactly 1 manifest matching *-${rsuffix}.BUILD-MANIFEST.txt in $BUCKET, found $nman."
  [ -n "$mans" ] && say "$mans"
  say "Superseded release objects must be removed as part of the upload step — clean the bucket, then re-verify."
  exit 1
fi
$GS cat "$mans" $A > "$tmp/manifest" 2>/dev/null || { say "FATAL: cannot read served manifest"; exit 1; }
$GS cat "$BUCKET/CHECKSUM" $A > "$tmp/CHECKSUM" 2>/dev/null || { say "FATAL: cannot read served CHECKSUM"; exit 1; }
servedc=$(awk -F': *' '/^git_commit/{print $2; exit}' "$tmp/manifest")
asha=$(awk -F': *' '/^artifact_sha256/{print $2; exit}' "$tmp/manifest")

say "=== verify (fail-closed) ==="
# 1. served == tag (the invariant that drifted)
# 12-char display, deliberately: a 7-char prefix MASKED a real mismatch at the 20260723 cut (a
# hand-typed GIT_COMMIT shared the 7-char prefix with the tag commit; the gate failed correctly but
# the message showed two identical strings).
[ "$servedc" = "$tagc" ]; res $? "served commit ${servedc:0:12} == tag $TAG (${tagc:0:12})"
# 2. the served CHECKSUM is authentically OURS — pinned fingerprint, not merely "a" Good signature
# (review MINOR-7: any-key grep would accept a signature from any key in the local keyring; flash.sh
# has pinned VALIDSIG since day one — same standard here).
FPR="71C16676F9D40A4CE0C6EB6608B14BC398311101"
gpg --import "$KEY" >/dev/null 2>&1 || true
# Extract the signed BODY and compare against that, never the container: gpg reports VALIDSIG on a
# clearsigned file with unsigned text prepended, so grepping the raw file would accept attacker-supplied
# lines sitting outside the signature (same root cause as the 2026-08-06 flash.sh fix).
gpg --status-fd 1 --output "$tmp/CHECKSUM.signed" --yes --decrypt "$tmp/CHECKSUM" 2>/dev/null | grep -q "VALIDSIG $FPR"
res $? "served CHECKSUM carries a valid signature from the PINNED release key (${FPR:0:8}...)"
# 3. the served image's sha is the one inside that signed CHECKSUM (binds manifest <-> signed bytes).
# ANCHORED to the artifact's own line: an unanchored match accepted the sha of ANY signed artifact, so a
# trojan image whose manifest quoted the kernel rpm's sha would have passed.
aname=$(awk -F': *' '$1 ~ /^artifact *$/{print $2; exit}' "$tmp/manifest")
[ -n "$asha" ] && [ -n "$aname" ] && grep -qE "^${asha}  ${aname}$" "$tmp/CHECKSUM.signed"
res $? "served image sha ${asha:0:12}... is the signed sha for $aname"

# 3b. the image object is actually SERVED. Metadata can be perfect while the
# object is missing or truncated (a failed 1.5 GB upload, or the wrong file
# removed during the manual #78 rotation).
$GS ls "$BUCKET/$aname" $A >/dev/null 2>&1; res $? "served image object $aname exists in the bucket"

# 4 (#59/#77). each served rpm: present in the bucket, sha inside the signed CHECKSUM.
# Manifests older than the rpm pipeline have no rpm lines — skipped, not failed (old releases verify).
sawrpm=0
for pair in "kernel_rpm kernel_rpm_sha256 kernel" "kmod_rpm kmod_rpm_sha256 kmod" "userspace_rpm userspace_rpm_sha256 userspace"; do
  set -- $pair
  prpm=$(awk -F': *' -v k="$1" '$1 ~ "^"k" *$" {print $2; exit}' "$tmp/manifest")
  psha=$(awk -F': *' -v k="$2" '$1 ~ "^"k" *$" {print $2; exit}' "$tmp/manifest")
  if [ -n "$prpm" ]; then
    sawrpm=1
    case "$prpm" in *[\*\?\[]*) say "FATAL: rpm name from the served manifest contains a glob: $prpm"; exit 1;; esac
    $GS ls "$BUCKET/$prpm" $A >/dev/null 2>&1; res $? "$3 rpm $prpm is served from the bucket"
    [ -n "$psha" ] && grep -qF "$psha" "$tmp/CHECKSUM"; res $? "served $3 rpm sha ${psha:0:12}... is covered by the signed CHECKSUM"
  fi
done
[ "$sawrpm" = 1 ] || say "  note: manifest predates the rpm pipeline (no rpm lines) — rpm checks skipped"

# 5. HEAD-advanced: a heads-up, never a failure (durable invariant is served == tag)
head=$(git rev-parse HEAD 2>/dev/null)
[ "$head" = "$tagc" ] || say "  WARN: HEAD (${head:0:7}) is past the released tag $TAG (${tagc:0:7}). Fine if those commits are not meant to ship yet; re-cut + re-tag before the next release if they are."

say ""
[ "$fail" = 0 ] && { say "RELEASE-INTEGRITY: OK — served == tag $TAG, signature + sha bound."; exit 0; } \
                || { say "RELEASE-INTEGRITY: FAILED — do not announce this release."; exit 1; }
