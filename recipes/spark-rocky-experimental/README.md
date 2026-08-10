# spark-rocky-experimental — the staging tier

Declared in [`.sparkrun/registry.yaml`](../../.sparkrun/registry.yaml) with `visible: false`:
hidden from listings, resolvable by name (`@spark-rocky-experimental/<recipe>`).

**Admission:** only recipes actively being driven toward a receipt. Abandoned entries are pruned
at each release cut. Promotion to the official tier requires a committed receipt in
[`../../receipts/`](../../receipts/) plus a byte-binding row in
[`../spark-rocky/PROMOTIONS.tsv`](../spark-rocky/PROMOTIONS.tsv).

Empty at go-live (2026-08-10). The one not-yet-promotable config at the `recipes/` root (the
v1-form qwen3.5 variant) waits on its sparkrun-v2 re-expression plus a fresh receipt (#94), not
on this tier — the mods-resolution question that gated promotion was answered same-day (#91).
