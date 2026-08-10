#!/bin/bash
# Plug Check (#24) — drift sensor for the pins that actually gate a rebuild. NO timer, NO side effects.
# Per tracked pin: current (config/versions.env) vs upstream (machine-readable feed) -> MATCH | DRIFT.
# Exit 0 if the real pins match, 2 if any drifted — so the Phase-2 watcher is just: this + notify-on-exit-2.
#
# Feeds are the build's own trust path, all machine-readable (no HTML scraping of anything load-bearing):
#   CLK     ctrliq/kernel-src-tree ciq-6.18.y branch tip      (THE shipping pin since the clk default,
#                                                              2026-07-17 — refresh when CLK moves)
#   DRIVER  NVIDIA/open-gpu-kernel-modules GitHub releases    (via gh, authenticated -> no rate limit)
#   KVER    kernel.org releases.json                          (INFORMATIONAL since the clk default: the
#                                                              kernelorg A/B pin; context, never triggers)
#   ROCKY   Rocky mirror directory listing                    (INFORMATIONAL: a new 10.x notifies, never triggers)
#   SERVING spark-arena/dgx-vllm build-index.json             (INFO while <31d stale; DRIFT past a month —
#                                                              the mirror moves ~daily, the pin ages monthly, #71)
#
# CUDA is PINNED (config/versions.env CUDA_VER) — a deliberate hold at the serving-container version (#28),
# NOT a drift-tracked feed: bumping it is a reviewable diff, never an auto-pickup, so there is no DRIFT
# row to fire. container-toolkit + docker DO float from the gpgcheck'd repos (a rebuild picks up current for
# free — no pin, no scraper to rot), so they are deliberately absent here.
# Runs on a dev box (needs curl + python3 + gh); it is a sensor for the human who does the manual pin bump
# (the by-hand flow, decided 2026-06-29 — #26 closed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"   # CLK_COMMIT, KVER, DRIVER_VER, ROCKY_RELEASEVER
source "$HERE/../config/serving-images.env"   # SERVING_IMAGE_TAG (#71; June receipt digests ride along, unused here)

drift=0; checkfail=0
# A fetch failure is NOT drift (audit #70 A13): "upstream moved past our pin" and "the sensor could not
# reach upstream" are different diagnoses — the first opens a pin-drift issue, the second must fail the
# run loudly (exit 3) so a network blip or API change never files a false drift report.
row(){ local s="MATCH"
  if [ "$3" = "FETCH-FAIL" ]; then s="CHECK-FAIL"; checkfail=1
  elif [ "$2" != "$3" ]; then s="DRIFT"; drift=2; fi
  printf '%-8s current=%-12s upstream=%-12s [%s]\n' "$1" "$2" "$3" "$s"; }

# CLK_COMMIT — the SHIPPING pin: ciq-6.18.y branch tip. kernel-src-tree is public, but org SAML can
# block AUTHENTICATED gh tokens on it — unauthenticated curl is the reliable path (rate limits are
# fine at a weekly cadence); gh is the fallback, not the primary.
cup=$(curl -fsSL --max-time 15 https://api.github.com/repos/ctrliq/kernel-src-tree/branches/ciq-6.18.y 2>/dev/null | python3 -c '
import sys, json
try: print(json.load(sys.stdin)["commit"]["sha"])
except Exception: print("")')
[ -n "$cup" ] || cup=$(gh api repos/ctrliq/kernel-src-tree/branches/ciq-6.18.y --jq .commit.sha 2>/dev/null)
cup="${cup:-FETCH-FAIL}"
row CLK "${CLK_COMMIT:0:12}" "${cup:0:12}"

# KVER — latest 6.18.y from kernel.org. INFORMATIONAL since the clk default (2026-07-17): this is
# the kernelorg A/B pin, context for how far CLK trails upstream — it never triggers a rebuild.
kup=$(curl -fsSL --max-time 15 https://www.kernel.org/releases.json 2>/dev/null | python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)["releases"]
    v = [x["version"] for x in r if x["version"].startswith("6.18.")]
    print(v[0] if v else "NONE-6.18-EOL")
except Exception:
    print("")')
printf '%-8s current=%-12s upstream=%-12s [INFO]\n' "KVER" "$KVER" "${kup:-FETCH-FAIL}"

# DRIVER_VER — newest release ON OUR PINNED BRANCH (DRIVER_BRANCH, versions.env). The old rule —
# releases/latest, branch-agnostic — is the verified mechanism that walked us onto a zero-commitment
# preview branch without a decision (#80/#83), and NVIDIA ships same-day multi-branch waves
# (2026-08-03: 610/595/580 together), so every wave re-rolls that dice. Same-branch tip = DRIFT;
# the highest release on any OTHER branch prints as INFO — a branch transition is a human
# posture decision (#83), never an auto-pickup.
dall=$(gh api "repos/NVIDIA/open-gpu-kernel-modules/releases?per_page=30" --jq '.[] | "\(.tag_name) \(.published_at)"' 2>/dev/null)
if [ -n "$dall" ]; then
  dup=$(printf '%s\n' "$dall" | awk -v b="^${DRIVER_BRANCH}\\." '$1 ~ b {print $1}' | sort -V | tail -1)
  row DRIVER "$DRIVER_VER" "${dup:-FETCH-FAIL}"
  dcross=$(printf '%s\n' "$dall" | awk -v b="^${DRIVER_BRANCH}\\." '$1 !~ b {print $1}' | sort -V | tail -1)
  # Orphan tripwire (#83): the NFB posture's one real risk is silent branch death, and the death
  # signal is an ABSENCE — a release wave that ships sibling branches while ours goes quiet. If the
  # pinned branch has shipped nothing in ORPHAN_WINDOW_DAYS (~2x the observed 610 release gap) while
  # a sibling has something newer, escalate to WARN and set the drift exit code so the weekly run
  # FILES AN ISSUE instead of printing an INFO line nobody reads.
  ORPHAN_WINDOW_DAYS=120
  dlast=$(printf '%s\n' "$dall" | awk -v b="^${DRIVER_BRANCH}\\." '$1 ~ b {print $2}' | sort | tail -1)
  xlast=$(printf '%s\n' "$dall" | awk -v b="^${DRIVER_BRANCH}\\." '$1 !~ b {print $2}' | sort | tail -1)
  if [ -n "$dcross" ]; then
    age_days=9999
    [ -n "$dlast" ] && age_days=$(( ( $(date -u +%s) - $(date -u -d "$dlast" +%s) ) / 86400 ))
    if [ "$age_days" -gt "$ORPHAN_WINDOW_DAYS" ] && [ -n "$xlast" ] && [ "$xlast" \> "${dlast:-}" ]; then
      printf '%-8s current=%-12s upstream=%-12s [WARN] pinned branch %s quiet %sd while siblings ship — may be ORPHANED; run the #83 contingency (docs/build/branch-transition.md)\n' "DRV-XBR" "branch-$DRIVER_BRANCH" "$dcross" "$DRIVER_BRANCH" "$age_days"
      drift=2
    else
      printf '%-8s current=%-12s upstream=%-12s [INFO] highest non-%s release; branch transition = human decision (#83)\n' "DRV-XBR" "branch-$DRIVER_BRANCH" "$dcross" "$DRIVER_BRANCH"
    fi
  fi
else
  row DRIVER "$DRIVER_VER" "FETCH-FAIL"
fi

# SERVING — the dgx-vllm mirror pin (#71). The mirror snapshots eugr's vLLM nightly ~daily, so "a newer
# tag exists" is the permanent steady state, not drift — INFO normally. It becomes DRIFT only when the
# pinned tag has aged >31 days behind the newest mirror tag: the benchmark surface is a month past the
# board's runtime, the exact confound the pin exists to control (a stale meter, not a broken one).
# Feed: build-index.json at dgx-vllm HEAD — machine-readable, same trust path the pin came from.
sup=$(curl -fsSL --max-time 15 https://raw.githubusercontent.com/spark-arena/dgx-vllm/main/build-index.json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    tags = [e["tag"] for e in d if e.get("variant") == "nightly"]
    print(tags[-1] if tags else "")
except Exception: print("")')
if [ -z "${SERVING_IMAGE_TAG:-}" ]; then
  printf '%-8s current=%-12s upstream=%-12s [INFO]\n' "SERVING" "unpinned" "${sup:-FETCH-FAIL}"
elif [ -z "$sup" ]; then
  row SERVING "$SERVING_IMAGE_TAG" "FETCH-FAIL"
else
  # Data goes in as ARGV, never interpolated into the program text: $sup comes from a third-party
  # repo's build-index.json, and a crafted tag would otherwise execute as Python -- on a dev box that
  # holds the gh token, the Spark SSH keys, and the release-signing key.
  gap=$(python3 -c '
import sys
from datetime import date
p, u = sys.argv[1][:8], sys.argv[2][:8]
d = lambda s: date(int(s[:4]), int(s[4:6]), int(s[6:8]))
print((d(u) - d(p)).days)' "$SERVING_IMAGE_TAG" "$sup" 2>/dev/null)
  if [ -n "$gap" ] && [ "$gap" -gt 31 ]; then
    row SERVING "$SERVING_IMAGE_TAG" "$sup"
  else
    printf '%-8s current=%-12s upstream=%-12s [INFO +%sd]\n' "SERVING" "$SERVING_IMAGE_TAG" "$sup" "${gap:-?}"
  fi
fi

# Rocky point release — INFORMATIONAL only (no pin; we built on 10.2; a new 10.x notifies, never auto-triggers).
rup=$(curl -fsSL --max-time 15 https://dl.rockylinux.org/pub/rocky/ 2>/dev/null \
  | grep -oE 'href="1[0-9]\.[0-9]+/"' | grep -oE '1[0-9]\.[0-9]+' | sort -V | tail -1)
printf '%-8s current=%-12s upstream=%-12s [INFO]\n' "ROCKY" "$ROCKY_RELEASEVER (10.2)" "${rup:-FETCH-FAIL}"

# BOXQ — the Spark work-queue linger tripwire (2026-08-10: "idle time on that machine is a bug").
# box-labeled open issues ARE the box's work queue; the standing rule is any session that touches
# the Spark drains the queue head before its own work. A head older than QMAX_DAYS is lingering —
# DRIFT, same severity as a stale pin. Empty queue = MATCH; gh failure = CHECK-FAIL, never drift.
QMAX_DAYS=7
bq=$(gh issue list --repo maxspevack/spark-rocky --label box --state open --json number,createdAt 2>/dev/null) || bq=""
if [ -z "$bq" ]; then
  row BOXQ "queue" "FETCH-FAIL"
else
  read -r qn qage <<<"$(printf '%s' "$bq" | python3 -c '
import sys, json, datetime
q = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc)
ages = [(i["number"], (now - datetime.datetime.fromisoformat(i["createdAt"].replace("Z","+00:00"))).days) for i in q]
n, a = max(ages, key=lambda x: x[1]) if ages else (0, -1)
print(n, a)')"
  if [ "$qage" = "-1" ]; then
    printf '%-8s current=%-12s upstream=%-12s [MATCH]\n' "BOXQ" "empty" "empty"
  elif [ "$qage" -gt "$QMAX_DAYS" ]; then
    printf '%-8s current=%-12s upstream=%-12s [DRIFT] #%s has lingered %sd (>%sd) — drain it or kill it\n' "BOXQ" "#$qn ${qage}d" "${QMAX_DAYS}d-max" "$qn" "$qage" "$QMAX_DAYS"; drift=2
  else
    printf '%-8s current=%-12s upstream=%-12s [INFO] queue head #%s age %sd; drains when the box frees\n' "BOXQ" "#$qn ${qage}d" "${QMAX_DAYS}d-max" "$qn" "$qage"
  fi
fi

# Exit contract: 0 = pins match; 2 = real drift (the workflow opens/updates the pin-drift issue);
# 3 = a tracked row could not be verified (the workflow goes RED — fix the sensor, not the pins).
# A verified drift outranks a fetch failure: it is actionable regardless.
[ "$drift" = 2 ] && exit 2
[ "$checkfail" = 1 ] && exit 3
exit 0
