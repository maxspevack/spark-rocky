# tuning/ — GB10 kernel configs, receipt-backed

Tuned Triton kernel configurations for the DGX Spark GB10, generated on this stack's own
hardware (methodology + evidence: the receipts named in [`TUNING.tsv`](TUNING.tsv), and the
diagnosis chain those receipts cite). sparkrun materializes this directory
into every consumer's registry checkout (`tuning_subpath` in
[`.sparkrun/registry.yaml`](../.sparkrun/registry.yaml); sync + sha256 verified on two consumers).
**The on-serve auto-mount does NOT yet fire for URL-added registries at sparkrun 0.3.1** — the
registry checkout carries the configs but the serve-time copy to the local tuning cache no-ops
(observed on a current checkout; tracked in the repo issues). Until that resolves upstream, mount
the file yourself or set `VLLM_TUNED_CONFIG_FOLDER` at the registry checkout's `tuning/vllm/` —
both vLLM lookups honor the folder before the bundled defaults.

Added the registry before the shelf existed? As of sparkrun 0.3.1, `registry add` materializes
manifest fields once and `registry update` never re-reads them — `sparkrun registry remove
spark-rocky && sparkrun registry add <repo URL>` picks up the shelf.

| File | Covers | Receipt |
|---|---|---|
| `vllm/E=512,N=2688,device_name=NVIDIA_GB10.json` | Nemotron-3-Super fused-MoE: decode keys M=1,2,4,8 tuned (re-race-validated; +3.5% geomean over the default heuristic at kernel level) + rows M=16..4096 pinned to the default heuristic's own per-M choices, so prefill-scale M can no longer land on a small-M-tuned config (the measured −2.35% pp2048 snap; re-gated to −0.59% [−1.74,+0.55], n=32/arm) | `moe-config-kernel-AB-2026-08-12.txt` |


**Held off the shelf (2026-08-12):** the Mamba `selective_state_update` config — generated and
generation-receipted, but pulled pending its own kernel-level A/B: the serve-level gates could
not attribute a small prefill residual between the two configs at their resolution, and this
shelf's contract is receipts, not vibes. It returns with its receipt.

**Honesty box:** the MoE ladder deliberately stops at M=8 — vLLM's lookup is nearest-key (no
fallback), so decode traffic (concurrency 1–10) lands on tuned keys while large-batch prefill
would snap to the M=8 entry — measured at −2.35% pp2048; rows M=16..4096 carry the default
heuristic's own values at those keys, and the re-gate on this artifact PASSED: pp2048 −0.59%
[−1.74, +0.55] (n=32/arm; receipts/moe-config-serve-gates-2026-08-12.txt). Serve-level decode is
a wash at the harness's resolution — the claim is the kernel-level win, deliberately. (Note the
heuristic's internal breakpoints don't all align with nearest-key snap basins, so a few mid-M
bands resolve differently than stock; the pp2048 receipt is the evidence that this nets ~zero.) Admission to this shelf follows the ledger contract above — no receipt, no row,
no serve.
