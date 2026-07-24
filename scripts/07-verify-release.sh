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
chk(){ if eval "$1"; then say "  ok: $2"; else say "  VERIFY-FAIL: $2"; fail=1; fi; }

tagc=$(git rev-list -n1 "$TAG" 2>/dev/null) || { say "FATAL: tag '$TAG' not found locally"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

say "=== fetch served release metadata from $BUCKET ==="
$GS cat "$BUCKET"/*BUILD-MANIFEST.txt $A > "$tmp/manifest" 2>/dev/null || { say "FATAL: cannot read served manifest"; exit 1; }
$GS cat "$BUCKET/CHECKSUM" $A > "$tmp/CHECKSUM" 2>/dev/null || { say "FATAL: cannot read served CHECKSUM"; exit 1; }
servedc=$(awk -F': *' '/^git_commit/{print $2; exit}' "$tmp/manifest")
asha=$(awk -F': *' '/^artifact_sha256/{print $2; exit}' "$tmp/manifest")

say "=== verify (fail-closed) ==="
# 1. served == tag (the invariant that drifted)
chk "[ \"$servedc\" = \"$tagc\" ]"  "served commit ${servedc:0:7} == tag $TAG (${tagc:0:7})"
# 2. the served CHECKSUM is authentically ours
gpg --import "$KEY" >/dev/null 2>&1 || true
chk "gpg --verify '$tmp/CHECKSUM' 2>&1 | grep -q 'Good signature'"  "served CHECKSUM carries a Good GPG signature"
# 3. the served image's sha is the one inside that signed CHECKSUM (binds manifest <-> signed bytes)
chk "[ -n \"$asha\" ] && grep -q \"$asha\" '$tmp/CHECKSUM'"  "served image sha ${asha:0:12}... is covered by the signed CHECKSUM"

# 4 (#59). the served kernel rpm: present in the bucket, and its sha is inside the signed CHECKSUM.
# Manifests older than the rpm pipeline have no kernel_rpm line — skipped, not failed (old releases verify).
krpm=$(awk -F': *' '/^kernel_rpm  /{print $2; exit}' "$tmp/manifest")
ksha=$(awk -F': *' '/^kernel_rpm_sha256/{print $2; exit}' "$tmp/manifest")
if [ -n "$krpm" ]; then
  chk "$GS ls '$BUCKET/$krpm' $A >/dev/null 2>&1"  "kernel rpm $krpm is served from the bucket"
  chk "[ -n \"$ksha\" ] && grep -q \"$ksha\" '$tmp/CHECKSUM'"  "served kernel rpm sha ${ksha:0:12}... is covered by the signed CHECKSUM"
else
  say "  note: manifest predates the rpm pipeline (no kernel_rpm) — rpm checks skipped"
fi
# 4b (#77). same binding for the kmod + userspace rpms (manifests predating them skip).
for pair in "kmod_rpm kmod_rpm_sha256 kmod" "userspace_rpm userspace_rpm_sha256 userspace"; do
  set -- $pair
  prpm=$(awk -F': *' -v k="$1" '$1 ~ "^"k" *$" {print $2; exit}' "$tmp/manifest")
  psha=$(awk -F': *' -v k="$2" '$1 ~ "^"k" *$" {print $2; exit}' "$tmp/manifest")
  if [ -n "$prpm" ]; then
    chk "$GS ls '$BUCKET/$prpm' $A >/dev/null 2>&1"  "$3 rpm $prpm is served from the bucket"
    chk "[ -n \"$psha\" ] && grep -q \"$psha\" '$tmp/CHECKSUM'"  "served $3 rpm sha ${psha:0:12}... is covered by the signed CHECKSUM"
  fi
done

# 5. HEAD-advanced: a heads-up, never a failure (durable invariant is served == tag)
head=$(git rev-parse HEAD 2>/dev/null)
[ "$head" = "$tagc" ] || say "  WARN: HEAD (${head:0:7}) is past the released tag $TAG (${tagc:0:7}). Fine if those commits are not meant to ship yet; re-cut + re-tag before the next release if they are."

say ""
[ "$fail" = 0 ] && { say "RELEASE-INTEGRITY: OK — served == tag $TAG, signature + sha bound."; exit 0; } \
                || { say "RELEASE-INTEGRITY: FAILED — do not announce this release."; exit 1; }
