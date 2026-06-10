# docs/ — the explanation layer

The repo delivers two things (a Live USB, and a benchmark-reproduction mechanism); these docs explain how
each works and why the result is trustworthy. The top-level [`../README.md`](../README.md) is the entry point.

| Doc | Purpose | Read it when |
|---|---|---|
| [`build-and-install.md`](build-and-install.md) | **Deliverable #1.** Build the Live USB (`01`→`04`), install to the NVMe, verify with proof-of-life. The script taxonomy (pipeline vs first-install helpers). | You want to stand up the box. |
| [`reproduce-pipeline.md`](reproduce-pipeline.md) | **Deliverable #2.** Reproduce any published single-host entry: the leaderboard-entry→recipe mapping, serve, the canonical full `llama-benchy` matrix, compare. Plus the operational sensors. | You want to reproduce or refute a number. |
| [`scoreboard.md`](scoreboard.md) | The target ledger — published-vs-ours per single-host entry, with status. | You want to know what's been reproduced. |
| [`software-stack.md`](software-stack.md) | The three software environments (host / serving container / benchmark client) and why "PyTorch not found" is correct, not a gap. | You're confused about what runs where. |
| [`stack-and-delta.md`](stack-and-delta.md) | Layer-by-layer: exactly what we swapped (host) vs held constant (hardware + AI stack), and the one confound (vLLM version drift). | You want the controlled-experiment argument for a CEO/CTO. |
