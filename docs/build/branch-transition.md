# Driver branch transition — the #83 contingency runbook

The shipped driver rides the **610 New Feature Branch** deliberately (#83 disposition, 2026-08-06):
newest viable line, every published receipt lives there, and the 64k destination (#65) is reachable
only from the NFB lineage. The price of that posture is that an NFB carries **no formal support
commitment** — NVIDIA's lifecycle policy gives it "N/A" — so it can stop without notice. This
runbook is what makes that a Tuesday instead of an incident. It is written in calm, for execution
under a CVE clock, by whoever is at the keyboard (the delegation seam: nothing here needs Max
specifically except upstream posts and the release signature).

## When this fires

1. **The orphan tripwire** — `drift-check.sh` prints `DRV-XBR … [WARN] … may be ORPHANED` and exits
   drift (the weekly run files an issue): the pinned branch shipped nothing in ~120 days while a
   sibling branch did. Verified firing 2026-08-06 (falsification test against dead branch 590).
2. **The #1269 fix ships on a non-610 branch first** — the reopen trigger stated on #65. The
   calculus genuinely reopens: the destination branch may no longer be the NFB line.
3. **A ≥4 GiB fault appears on the shipped 4k stack** — assumption 2 of the decision doc falsified.
   Skip deliberation: 580 is the only #1269-clean line; cross immediately, performance be damned.

## Step 0 — MANDATORY: the crossing A/B (no pin crossing without it)

Decided at ratification (2026-08-06): we do **not** pre-price candidate branches — the number
perishes while both branches move. It is measured **once, here, when it is load-bearing**.

- Full 104-cell driver-only A/B on the then-live candidates, same box / same kernel / same pinned
  serving image / same recipe, **throttle-clean both legs** (`check-throttle.sh` gates; chunked
  protocol if the box is heat-saturated). Precedent + format:
  `receipts/reproduce-Qwen3.5-0.8B-driver-AB-580-vs-610-2026-07-31.txt`.
- Candidate order when the trigger is orphaning: **595 first** (Production, ≈1 yr commitment) —
  take it if it measures ≈1.00×; **580 second** (LTSB) — the contingency of record at a known
  −10.4% (measured 2026-07-31). A bad known price beats an unknown one; an unknown good price
  beats both, which is what the A/B is for.
- Commit the receipt BEFORE the pin moves. The published receipt corpus is branch-qualified from
  that moment (existing receipts stay true — they name the branch they measured).

## Step 1 — pins (one reviewable diff)

In `config/versions.env`, same commit:
- `DRIVER_VER=<new>` and `DRIVER_BRANCH=<new branch>` (a test invariant fails if they disagree).
- `DRIVER_SHA256`: TOFU at bump — download the `.run` over TLS, run its embedded `--check`, pin the
  sha (NVIDIA publishes no signed sums; this is the documented trust model).
- `DRIVER_64K_SAFE`: **do not touch.** Admission is paid separately (below), never during a crossing.

## Step 2 — the landmine, named

`--no-install-libglvnd` is **required** on any 5xx-series `.run` userspace install: the installer
uninstalls the incumbent userspace **before** its glvnd conflict check aborts, which strands the box
driverless — this ate the metal's driver on 2026-07-28 (recorded in the A/B receipt). The `02c`
path-diff RPM packaging regenerates per driver; check the glvnd exclusion survives it.

## Step 3 — build + gates, standard order

`01`→`05` (kernel unchanged → `02b`/`02c`/`04`/`05`), then in order: `serve-gate.sh` (GATE-PASS),
`05b-boot-gate.sh` (BOOT-GATE: PASS on the booted artifact), dmesg census vs
`docs/build/dmesg-baseline.md` (delta must be attributed), `upgrade-metal.sh` (stages the prior
driver as the rollback dir automatically). Rollback = the GRUB fallback entry + the staged
`driver-rollback-<ver>/` dir; both exist before the metal reboots or the transition stops.

## Step 4 — the #1269 reproducer, every bump (crossing or not)

At **every** driver bump, run the ≥4 GiB reproducer (`bigalloc`-class, from the #1269 case file) on
the built stack and record PASS/FAULT in the bump receipt. Minutes of runtime. This is how a quietly
shipped fix is caught the day we touch it: a PASS on any driver is the `DRIVER_64K_SAFE` admission
evidence, and with the gate already in `05`, 64k restoration is two reviewable lines (#65).

## Step 5 — paper

CHANGELOG entry (branch + why + the A/B receipt path); `docs/build/platform-deltas.md` branch table
row moves; `docs/build/software-stack.md` driver line; drift sensor confirms `DRIVER MATCH` on the
new branch on its next run; #83 gets the crossing record. Release cut per `build.md` — the boot
gate and the signature are unchanged.
