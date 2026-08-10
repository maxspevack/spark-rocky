# Benchmark it — the numbers, replicated and compared

What the stack delivers, how to reproduce it yourself, and how it stacks up against published spark-arena.com results.

- [`proof.md`](proof.md) — the 30-second claim and the parity table. **Start here.**
- [`reproduce-pipeline.md`](reproduce-pipeline.md) — how to measure, both ways: the receipt-grade path (pull any published entry's recipe, serve, measure, compare) **and the board's own harness** (sparkrun + the official v2 profile, validated on this host — the closing section).
- [`scoreboard.md`](scoreboard.md) — ours vs published, in three chapters: parity, the frontier lanes, and the measurement discipline behind the numbers.

**Don't want to reproduce — just want to run the proven configs?** This repo is a sparkrun
registry: `scripts/install-sparkrun.sh`, then
`sparkrun registry add https://github.com/maxspevack/spark-rocky`, then
`sparkrun run @spark-rocky/<recipe>`. Tiers, promotion rules, and the honest pinned-vs-unpinned
split: [`../../recipes/README.md`](../../recipes/README.md).
