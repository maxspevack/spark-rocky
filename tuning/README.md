# tuning/ — GB10 kernel configs, receipt-backed

Tuned Triton kernel configurations for the DGX Spark GB10, generated on this stack's own
hardware (methodology + evidence: the receipts named in [`TUNING.tsv`](TUNING.tsv), and the
diagnosis chain those receipts cite). sparkrun syncs this directory automatically when serving
`@spark-rocky` recipes (`tuning_subpath` in [`.sparkrun/registry.yaml`](../.sparkrun/registry.yaml))
and mounts it into the serve container via `VLLM_TUNED_CONFIG_FOLDER` — both the fused-MoE and
Mamba SSM lookups in vLLM honor that folder before the bundled defaults.

Added the registry before the shelf existed? As of sparkrun 0.3.1, `registry add` materializes
manifest fields once and `registry update` never re-reads them — `sparkrun registry remove
spark-rocky && sparkrun registry add <repo URL>` picks up the shelf.

| File | Covers | Receipt |
|---|---|---|
| `vllm/E=512,N=2688,device_name=NVIDIA_GB10.json` | Nemotron-3-Super fused-MoE: decode keys M=1,2,4,8 tuned (re-race-validated; +3.5% geomean over the default heuristic at kernel level) + rows M=16..4096 pinned to the default heuristic's own per-M choices, so every M ≥ 13 resolves to exactly the stock config (the measured −2.35% pp2048 nearest-key snap, neutralized by construction) | `moe-config-kernel-AB-2026-08-12.txt` |


**Held off the shelf (2026-08-12):** the Mamba `selective_state_update` config — generated and
generation-receipted, but pulled pending its own kernel-level A/B: the serve-level gates could
not attribute a small prefill residual between the two configs at their resolution, and this
shelf's contract is receipts, not vibes. It returns with its receipt.

**Honesty box:** the MoE ladder deliberately stops at M=8 — vLLM's lookup is nearest-key (no
fallback), so decode traffic (concurrency 1–10) lands on tuned keys while large-batch prefill
would snap to the M=8 entry — measured at −2.35% pp2048 and neutralized: rows M=16..4096 carry
the default heuristic's own values, so above the tuned range the file is behavior-identical to no
file. Decode receipts: kernel A/B +3.5% geomean; paired serve long-cell +2.1% [−1.2,+5.5]. The
pp2048 re-gate on the pinned-rows artifact is the remaining receipt (owed before upstream PRs). Admission to this shelf follows the ledger contract above — no receipt, no row,
no serve.
