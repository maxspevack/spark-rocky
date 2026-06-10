# data/ — captured spark-arena reference data

The published numbers we reproduce against, captured so the comparison is auditable and re-pullable.

| File | What it is |
|---|---|
| `spark-arena-snapshot-2026-06-10.json` | **Point-in-time** capture of the full leaderboard (231 entries), keyed by test (`entriesByTest`). Each entry carries `benchmarkId` (a `sub…` submission id), `modelName`, `tokensPerSec`, `runtime`, `clusterSize`, etc. The live board changes as people submit — this is a dated reference, not a feed. |
| `published-raw-LFM2.5-350M-6a9c9b76.md` | The **full published `llama-benchy` matrix** for the LFM2.5-350M entry (`tg128 (c1)` = 222.77). The reference we compare our reproduction to. |
| `published-raw-Qwen3.5-35B-A3B-FP8-28879af7.md` | Same, for the Qwen3.5-35B-A3B-FP8 entry (`tg128 (c1)` = 50.75). |
| `fetch.sh` | **Reproduces the per-entry pulls.** Given a `benchmarkId` (sub-id) it resolves the recipe-permalink UUID via public Firestore, then pulls the published matrix (`raw-<sub>.md`) and the verbatim recipe (`recipe-<sub>.yaml`). |

## Regenerate

```bash
./fetch.sh sub1777989095056    # LFM2.5-350M  -> raw + recipe
./fetch.sh sub1772533296511    # Qwen3.5-35B-A3B-FP8
```

The entry→recipe mapping (Firestore `benchmarks/<sub-id>` → `recipePermalinkId` → `/api/{benchmarks,recipes}/<uuid>/raw`)
is explained in [`../docs/reproduce-pipeline.md`](../docs/reproduce-pipeline.md). The snapshot itself is a
manual capture of the live board; treat its date as authoritative for "the board as we saw it."
