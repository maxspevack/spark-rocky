# spark-rocky-experimental — the staging tier

Declared in [`.sparkrun/registry.yaml`](../../.sparkrun/registry.yaml) with `visible: false`:
hidden from listings, resolvable by name (`@spark-rocky-experimental/<recipe>`).

**Admission:** only recipes actively being driven toward a receipt. Abandoned entries are pruned
at each release cut. Promotion to the official tier requires a committed receipt in
[`../../receipts/`](../../receipts/) plus a byte-binding row in
[`../spark-rocky/PROMOTIONS.tsv`](../spark-rocky/PROMOTIONS.tsv).

Empty at go-live (2026-08-10) — the two promotion-pending Qwen configs sit at the `recipes/` root,
deliberately unserved, until the mods-resolution question (#91) answers whether their `mods/fix-*`
references resolve for registry consumers at all.
