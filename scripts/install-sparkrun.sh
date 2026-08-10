#!/usr/bin/env bash
# install-sparkrun.sh — install the pinned sparkrun release (the board's harness) on any host.
#
# The pin lives in config/serving-images.env (SPARKRUN_VERSION); this script carries NO version
# literal (CI-enforced), so the install command cannot drift from the pin — the exact rot class
# that hit the prose install line (#93). The image deliberately does not ship this tool: sparkrun
# is a client to a live service with a floating transitive closure; it has no business frozen in
# a dated signed image (#88/#92).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

source "$HERE/../config/serving-images.env"
[ -n "${SPARKRUN_VERSION:-}" ] || { echo "FATAL: SPARKRUN_VERSION missing/empty in config/serving-images.env" >&2; exit 1; }

command -v uv >/dev/null 2>&1 || {
  echo "FATAL: uv not found — install it first: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 1
}

uv tool install --force "sparkrun==$SPARKRUN_VERSION"

# Verify the work: on PATH, and the installed tool reports the pinned version. A pinned install
# that lands the wrong bits fails HERE, not downstream (the 2026-07-27 alpha commit-pin predated
# the very fix it was adopted for — a self-reported version is checked, not trusted).
command -v sparkrun >/dev/null 2>&1 || {
  echo "FATAL: sparkrun installed but not on PATH (uv tools land in ~/.local/bin)." >&2
  echo "       Run: uv tool update-shell   — then open a new shell and re-run this script." >&2
  exit 1
}
GOT=$(sparkrun --version 2>&1 || true)
# Anchored match, not substring: the pin must appear as a whole version token. A bare substring
# check is fail-OPEN for superstrings (0.3.1 inside 0.3.10 or 10.3.1) — the likeliest shadow is
# a NEWER install (uv tool upgrade), exactly the false-pass case.
if printf '%s' "$GOT" | grep -qE "(^|[^0-9.])${SPARKRUN_VERSION//./\\.}([^0-9.]|$)"; then
  echo "OK: sparkrun $SPARKRUN_VERSION installed and on PATH."
else
  echo "FATAL: installed sparkrun reports '$GOT'; the pin is $SPARKRUN_VERSION — a stale shim or second install is shadowing it." >&2
  exit 1
fi

cat <<'EOF'

Optional — this repo is also a sparkrun registry (receipt-backed GB10 recipes, #88):

    sparkrun registry add https://github.com/maxspevack/spark-rocky

The registry is the convenient UNPINNED channel: it tracks git HEAD and is covered by no release
signature. The receipts/ directory is the pinned one — registry recipes serve what was proven on
their receipt date and carry no maintenance cadence against upstream drift.

Recipes that carry mods execute the mod's run.sh in the container before the serve; sparkrun
asks before running hooks from an untrusted registry. 'sparkrun registry trust spark-rocky'
(or --trust at add time) skips that prompt by trusting this registry's current git HEAD —
that grant is yours to make, and no release signature covers it.
(Not run automatically: adding a registry is your trust decision, not this script's.)
EOF
