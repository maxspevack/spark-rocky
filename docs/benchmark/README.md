# Benchmark it

The stack's numbers and the evidence behind them — pick by what you want:

| You want to... | Go to | Costs you |
|---|---|---|
| **Run the proven configs** on your own Spark — no reproduction, no account | [the fast path](#run-the-proven-configs-the-fast-path), below | ~5 min of commands + the model pull and first-serve startup |
| **See the claim and the evidence** — what's proven, every number receipted | [`proof.md`](proof.md) | a 3-minute read |
| **Verify a number yourself** — reproduce any board entry, credential-free | [`reproduce-pipeline.md`](reproduce-pipeline.md) | an afternoon |
| **Read the full evidence ledger** — every measurement, confound, and discipline rule | [`scoreboard.md`](scoreboard.md) | reference material |

## The claim, in one line

Published [spark-arena.com](https://spark-arena.com) single-host numbers come back **at parity** on
this host (full-matrix medians 0.96–1.05×; re-proven at 1.010× on the pinned runtime, 2026-07-24) —
and on the board's NVFP4+MTP meta the same host measures **receipt-grade results statistically
indistinguishable from the single-node field, including a statistical tie with the board-best
Nemotron entry**. Every time a number moved, the mover was serving config — never the host.
Evidence: [`proof.md`](proof.md).

## Run the proven configs (the fast path)

This repo is a sparkrun registry. Every recipe in the official tier is backed by a committed receipt
in [`receipts/`](../../receipts/) and byte-bound to that receipt by CI — the registry cannot drift
ahead of its evidence. The [tuning shelf](../../tuning/) adds GB10-tuned
kernel configs (fused-MoE +3.5% geomean over the default heuristic at kernel level, receipt-bound
the same way); registry sync delivers the bytes to consumers, and `tuning/README.md` carries the
one-line mount until sparkrun's on-serve auto-mount fires for URL-added registries.

```bash
# from the repo root:
scripts/install-sparkrun.sh          # pinned harness install (uv); verifies its own work
sparkrun registry add https://github.com/maxspevack/spark-rocky
sparkrun run @spark-rocky/nemotron-3-super-120b-a12b-nvfp4-mtp-nst3-2026072302 --hosts localhost --rootful
```

The registry is the convenient **unpinned** channel (it tracks git HEAD, no release signature); the
receipts are the pinned one. Tiers, promotion rules, and the byte ledgers:
[`recipes/README.md`](../../recipes/README.md).
