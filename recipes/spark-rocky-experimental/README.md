# spark-rocky-experimental — the staging tier

Declared in [`.sparkrun/registry.yaml`](../../.sparkrun/registry.yaml) with `visible: false`:
hidden from listings, resolvable by name (`@spark-rocky-experimental/<recipe>`).

**Admission:** only recipes actively being driven toward a receipt. Abandoned entries are pruned
at each release cut. Promotion to the official tier requires a committed receipt in
[`../../receipts/`](../../receipts/) plus a byte-binding row in
[`../spark-rocky/PROMOTIONS.tsv`](../spark-rocky/PROMOTIONS.tsv).

Empty at go-live (2026-08-10), and still empty: the first candidate (#94's qwen3.5 v2
re-expression, 2026-08-11) was authored, receipted as a **local-recipe** serve byte-identical to
the promoted file, and promoted directly under the ledger contract (committed receipt +
PROMOTIONS row — all the contract requires) in a single overnight pass. The tier itself was not
exercised; it waits for a recipe that needs to live in staging across sessions.
