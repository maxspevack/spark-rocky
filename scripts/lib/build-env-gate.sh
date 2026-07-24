# build-env-gate.sh — THE fail-closed staleness gate on 01's build.env handoff. Sourced (not executed)
# by every stage that consumes the resolved kernel release: 02, 02b, 02c-adjacent consumers, 03, 04, 05,
# upgrade-metal. One implementation (audit #70 C1 — this replaced six copy-pasted blocks; the seventh
# script can no longer forget a divergent copy).
#
# Contract — the sourcing script must already have set:
#   $W               the work dir holding build.env
#   $KVER            the versions.env pin (kernelorg) — becomes the RESOLVED release on success
#   $KERNEL_SOURCE   clk | kernelorg (versions.env)
#   $CLK_COMMIT      the pinned CLK commit (versions.env; empty on kernelorg)
# On success: KVER = the resolved kernel release (e.g. 6.18.39-clk), and KRPM/BUILD_* are exported as
# 01 wrote them. A build.env from a different source or moved pin must not silently steer a build —
# exit 1 propagates to the sourcing script.
if [ -f "$W/build.env" ]; then
  PIN_KVER=$KVER; source "$W/build.env"
  [ "${BUILD_KERNEL_SOURCE:-}" = "$KERNEL_SOURCE" ] || { echo "FATAL: stale build.env (built from '${BUILD_KERNEL_SOURCE:-?}', pin is '$KERNEL_SOURCE') — rerun 01-build-kernel.sh"; exit 1; }
  [ "$KERNEL_SOURCE" != kernelorg ] || [ "$KVER" = "$PIN_KVER" ] || { echo "FATAL: stale build.env (KVER $KVER != pinned $PIN_KVER) — rerun 01-build-kernel.sh"; exit 1; }
  [ "$KERNEL_SOURCE" != clk ] || [ "${BUILD_CLK_COMMIT:-}" = "$CLK_COMMIT" ] || { echo "FATAL: stale build.env (CLK_COMMIT moved) — rerun 01-build-kernel.sh"; exit 1; }
else
  # ABSENT is as fatal as STALE (review M2): every consumer needs the RESOLVED release; without
  # build.env, KVER is the kernelorg A/B pin — under the clk default that names a kernel no artifact
  # in $W corresponds to, and stale kernelorg leftovers would be consumed silently.
  echo "FATAL: no $W/build.env — run 01-build-kernel.sh first (the resolved-release handoff is required)"; exit 1
fi
