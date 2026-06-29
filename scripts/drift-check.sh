#!/bin/bash
# Plug Check (#24) — drift sensor for the pins that actually gate a rebuild. NO timer, NO side effects.
# Per tracked pin: current (config/versions.env) vs upstream (machine-readable feed) -> MATCH | DRIFT.
# Exit 0 if the real pins match, 2 if any drifted — so the Phase-2 watcher is just: this + notify-on-exit-2.
#
# Feeds are the build's own trust path, all machine-readable (no HTML scraping of anything load-bearing):
#   KVER    kernel.org releases.json                         (same source 01-build-kernel verifies against)
#   DRIVER  NVIDIA/open-gpu-kernel-modules GitHub releases    (via gh, authenticated -> no rate limit)
#   ROCKY   Rocky mirror directory listing                    (INFORMATIONAL: a new 10.x notifies, never triggers)
#
# CUDA is PINNED (config/versions.env CUDA_VER) — a deliberate hold at the serving-container version (#28),
# NOT a drift-tracked feed: bumping it is a reviewable #26 diff, never an auto-pickup, so there is no DRIFT
# row to fire. container-toolkit + docker DO float from the gpgcheck'd repos (a rebuild picks up current for
# free — no pin, no scraper to rot), so they are deliberately absent here.
# Runs on a dev box (needs curl + python3 + gh); it is a sensor for the human who authors the #26 pin-bump PR.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"   # KVER, DRIVER_VER, ROCKY_RELEASEVER

drift=0
row(){ local s="MATCH"; if [ "$2" != "$3" ]; then s="DRIFT"; drift=2; fi
  printf '%-8s current=%-12s upstream=%-12s [%s]\n' "$1" "$2" "$3" "$s"; }

# KVER — latest 6.18.y stable/longterm from the kernel.org release index.
kup=$(curl -fsSL --max-time 15 https://www.kernel.org/releases.json 2>/dev/null | python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)["releases"]
    v = [x["version"] for x in r if x["version"].startswith("6.18.")]
    print(v[0] if v else "NONE-6.18-EOL")
except Exception:
    print("")')
row KVER "$KVER" "${kup:-FETCH-FAIL}"

# DRIVER_VER — latest published release of the open GPU kernel modules.
dup=$(gh api repos/NVIDIA/open-gpu-kernel-modules/releases/latest --jq .tag_name 2>/dev/null)
row DRIVER "$DRIVER_VER" "${dup:-FETCH-FAIL}"

# Rocky point release — INFORMATIONAL only (no pin; we built on 10.2; a new 10.x notifies, never auto-triggers).
rup=$(curl -fsSL --max-time 15 https://dl.rockylinux.org/pub/rocky/ 2>/dev/null \
  | grep -oE 'href="1[0-9]\.[0-9]+/"' | grep -oE '1[0-9]\.[0-9]+' | sort -V | tail -1)
printf '%-8s current=%-12s upstream=%-12s [INFO]\n' "ROCKY" "$ROCKY_RELEASEVER (10.2)" "${rup:-FETCH-FAIL}"

exit $drift
