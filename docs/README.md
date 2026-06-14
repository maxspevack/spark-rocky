# docs/ — the explanation layer

The repo delivers two things (a Live USB, and a benchmark-reproduction mechanism); these docs explain how
each works and why the result is trustworthy. The top-level [`../README.md`](../README.md) is the entry point.

| Doc | Purpose | Read it when |
|---|---|---|
| [`running.md`](running.md) | **Deliverable #1, the fast path.** Flash a USB with `flash.sh`, boot, run `validate.sh`. | You have a Spark and want it running now. |
| [`build-and-install.md`](build-and-install.md) | **Deliverable #1, from source.** Build the Live USB (`01`→`04`), install to the NVMe, verify with proof-of-life. The script taxonomy (pipeline vs first-install helpers). | You want to build the image yourself, or install to the NVMe. |
| [`reproduce-pipeline.md`](reproduce-pipeline.md) | **Deliverable #2.** Reproduce any published single-host entry: the leaderboard-entry→recipe mapping, serve, the canonical full `llama-benchy` matrix, compare. Plus the operational sensors. | You want to reproduce or refute a number. |
| [`scoreboard.md`](scoreboard.md) | The target ledger — published-vs-ours per single-host entry, with status. | You want to know what's been reproduced. |
| [`software-stack.md`](software-stack.md) | The full stack (host / serving container / benchmark client), the layer-by-layer delta vs DGX OS, why "PyTorch not found" is correct, and the controlled-experiment argument. | You want what-runs-where, the vs-DGX delta, or the CEO/CTO control argument. |
| [`platform-deltas.md`](platform-deltas.md) | Every boot-time `dmesg` delta on stock-mainline + the open driver, classified (carry / upstream / decline / benign), plus the firmware-currency conclusion. | You want the honest "what does stock surface, what did we decide" ledger. |
