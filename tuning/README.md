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
| `vllm/E=512,N=2688,device_name=NVIDIA_GB10.json` | Nemotron-3-Super fused-MoE, decode keys M=1,2,4,8 (re-race-validated; +3.5% geomean over the default heuristic at kernel level) | `moe-config-kernel-AB-2026-08-12.txt` |
| `vllm/headdim=64,dstate=128,device_name=NVIDIA_GB10,cache_dtype=float32.json` | Mamba `selective_state_update`, 13 effective-batch keys | `moe-tune-gb10-decode-keys-2026-08-12.txt` |

**Honesty box:** the MoE ladder deliberately stops at M=8 — vLLM's lookup is nearest-key (no
fallback), so decode traffic (concurrency 1–10) lands on tuned keys while large-batch prefill
snaps to the M=8 entry. The kernel-level A/B is the receipt so far; the serve-level gates (paired
tg CI, pp2048 snap non-regression) are owed before any serve-level claim. Admission to this shelf follows the ledger contract above — no receipt, no row,
no serve.
