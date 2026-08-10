# recipes/ — the registry tiers + the verbatim mirrors

Since 2026-08-10 this repo is a **sparkrun registry** (#88; namespace decided in #90):

```bash
sparkrun registry add https://github.com/maxspevack/spark-rocky
sparkrun run @spark-rocky/<recipe> ...
```

**The guarantee split, honestly:** the registry is the convenient **unpinned** channel — it tracks
git HEAD and is covered by no release signature. The **receipts** in [`../receipts/`](../receipts/)
are the pinned one. Registry recipes serve what was proven on their receipt date and carry no
maintenance cadence against upstream drift (the #29 posture, inherited).

| Tier | Directory | Resolved as | Admission |
|---|---|---|---|
| Official | [`spark-rocky/`](spark-rocky/) | `@spark-rocky/<recipe>` (listed) | Committed receipt in `receipts/` **+** a byte-binding row in [`spark-rocky/PROMOTIONS.tsv`](spark-rocky/PROMOTIONS.tsv) — CI enforces both directions |
| Experimental | [`spark-rocky-experimental/`](spark-rocky-experimental/) | `@spark-rocky-experimental/<recipe>` (by name only — `visible: false`) | Actively driven toward a receipt; pruned at release cuts |

Everything at this directory's **top level is deliberately unserved**, byte-guarded by
[`MIRRORS.tsv`](MIRRORS.tsv) (a no-drift-since-recorded tripwire — pull-time hashes were never
captured, and the ledger says so).

## Official tier

| File | Was (until 2026-08-10) | Receipts |
|---|---|---|
| [`spark-rocky/nemotron-3-super-120b-a12b-nvfp4-mtp-nst3-2026072302.yaml`](spark-rocky/nemotron-3-super-120b-a12b-nvfp4-mtp-nst3-2026072302.yaml) | `recipes/nemotron-3-super-120b-a12b-nvfp4-mtp-nst3-2026072302.yaml` | `reproduce-Nemotron-3-Super-NVFP4-mtp-2026-07-26.txt` (#73), re-proven under the official arena-v2 profile: `arena-v2-nemotron-3-super-nvfp4-mtp-1x-2026-08-10.*` |

## The verbatim mirrors — not ours

Each is the exact recipe spark-arena publishes for a leaderboard entry, pulled byte-for-byte from
`https://spark-arena.com/api/recipes/<permalink>/raw` and committed unchanged. They define how
`spark-vllm-docker`'s `run-recipe.sh` serves the model (the `vllm serve` command, flags, env, mods,
and the container tag). Reproducing an entry means running *its* recipe, not one we tuned — which
is exactly why they are never served under our namespace: republishing spark-arena's bytes as
`@spark-rocky/` would misattribute them, and sparkrun resolves board recipes natively.

| File | Entry | Container | Notes |
|---|---|---|---|
| `qwen3.5-35b-a3b-fp8-arena.yaml` | Qwen3.5-35B-A3B-FP8 (`28879af7`) | `vllm-node-tf5` | flashinfer, fp8 KV, `mods/fix-qwen3.5-autoround` |
| `qwen3.5-0.8b-arena.yaml` | Qwen3.5-0.8B (`sub1777633319098`) | `vllm-node` | public model, no token |
| `gemma-3-1b-it-arena.yaml` | gemma-3-1b-it (`sub1779455882567`) | `vllm-node-tf5` | HF-gated (token required to download) |
| `gpt-oss-120b-arena.yaml` | gpt-oss-120b | `vllm-node-mxfp4` | MXFP4 `--mxfp4-backend CUTLASS`, fp8 KV, flashinfer, ray |

## Receipt-backed, promotion-pending (#91)

Both reference `mods/fix-*` this repo does not carry; they promote to the official tier when #91
answers whether sparkrun resolves a recipe's mods across registries. Until then they stay here,
unserved, bytes frozen by `MIRRORS.tsv`.

| File | Derivation | Receipt |
|---|---|---|
| `qwen3.5-0.8b-arena-2026072302.yaml` | `qwen3.5-0.8b-arena.yaml` with a one-line `container:` delta to the permanent gen-2 tag (#71) — same serve, pinned runtime | `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt` |
| `qwen3.6-35b-a3b-nvfp4-board-2026072302.yaml` | The recipe behind the board's two top vLLM entries for Qwen3.6-35B-A3B-NVFP4 (permalink `1199b578`, entries 118.91 + 109.3, both single-node), re-expressed in sparkrun v2 template syntax — flag semantics verbatim; the published v1 form fails under sparkrun 0.2.40 (`{{…}}` escaping passes through to argparse) | `reproduce-Qwen3.6-35B-A3B-NVFP4-mtp-2026-07-25.txt` (#74) |

## Add a recipe

```bash
../data/fetch.sh <sub-id>      # writes recipe-<sub-id>.yaml; commit it here, renamed per the entry
```

Then add its row to [`MIRRORS.tsv`](MIRRORS.tsv) (sha256, path, receipt-or-`-`, date) — CI enforces
the root-integrity ledger and fails on any unledgered recipe at this level.

The `container:` field names which image `build-and-copy.sh` must produce (`vllm-node`, or
`vllm-node-tf5` for the transformers≥5 build). See
[`docs/benchmark/reproduce-pipeline.md`](../docs/benchmark/reproduce-pipeline.md).
