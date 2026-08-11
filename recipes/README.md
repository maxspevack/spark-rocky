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

| File | Was | Receipts |
|---|---|---|
| [`spark-rocky/nemotron-3-super-120b-a12b-nvfp4-mtp-nst3-2026072302.yaml`](spark-rocky/nemotron-3-super-120b-a12b-nvfp4-mtp-nst3-2026072302.yaml) | `recipes/nemotron-3-super-120b-a12b-nvfp4-mtp-nst3-2026072302.yaml` | `reproduce-Nemotron-3-Super-NVFP4-mtp-2026-07-26.txt` (#73). The arena-v2 receipts (`arena-v2-nemotron-3-super-nvfp4-mtp-1x-2026-08-10.*`) re-prove the same config *lineage* under the official profile — via the upstream experimental-registry recipe on a newer runtime, not these pinned bytes; provenance in the receipt |
| [`spark-rocky/qwen3.6-35b-a3b-nvfp4-board-2026072302.yaml`](spark-rocky/qwen3.6-35b-a3b-nvfp4-board-2026072302.yaml) | `recipes/qwen3.6-35b-a3b-nvfp4-board-2026072302.yaml` | `reproduce-Qwen3.6-35B-A3B-NVFP4-mtp-2026-07-25.txt` (#74). Board-lineage config re-expressed in sparkrun v2 (derivation in its `description:`); its `mods/fix-qwen3.6-chat-template` resolves from the default `eugr` registry — verified on a clean host (#91) |
| [`spark-rocky/qwen3.5-0.8b-arena-2026072302.yaml`](spark-rocky/qwen3.5-0.8b-arena-2026072302.yaml) | authored 2026-08-11 as the sparkrun-v2 re-expression of the v1-form variant at this root (which stays, frozen by `MIRRORS.tsv` — see the #94 section below); receipted as a local-recipe serve byte-identical to these bytes, promoted the same night | `sparkrun-serve-qwen3.5-0.8b-arena-2026072302-2026-08-11.txt` (#94): sparkrun 0.3.1 local-recipe serve, health 200, completion on the pinned gen-2 build, clean teardown |

Recipes that carry `mods:` copy and execute the mod's `run.sh` inside the container before the
serve. sparkrun asks before running hooks from an untrusted registry — `sparkrun registry trust
spark-rocky` (or `--trust` at add time) skips that prompt by granting shell-hook trust to this
registry's **current git HEAD**; that grant is yours to make, and no release signature covers it.

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

## The v1-form original (#94 — resolved 2026-08-11)

`qwen3.5-0.8b-arena-2026072302.yaml` at this root is **v1-form** and stays here unserved, bytes
frozen by `MIRRORS.tsv` — its rendered command ends in a dangling `\` under sparkrun 0.3.1
(verified through the pinned library), so sparkrun cannot serve it as-is. #94 resolved this with
a sparkrun-v2 re-expression (flag semantics verbatim), receipted under sparkrun on the GB10 and
**promoted to `spark-rocky/`** — see the promoted table above and
`receipts/sparkrun-serve-qwen3.5-0.8b-arena-2026072302-2026-08-11.txt`.

| File | Derivation | Receipt |
|---|---|---|
| `qwen3.5-0.8b-arena-2026072302.yaml` | `qwen3.5-0.8b-arena.yaml` with a one-line `container:` delta to the permanent gen-2 tag (#71) — same serve, pinned runtime | `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt` (v1, via `run-recipe.sh`) |

## Add a recipe

```bash
../data/fetch.sh <sub-id>      # writes recipe-<sub-id>.yaml; commit it here, renamed per the entry
```

Then add its row to [`MIRRORS.tsv`](MIRRORS.tsv) (sha256, path, receipt-or-`-`, date) — CI enforces
the root-integrity ledger and fails on any unledgered recipe at this level.

The `container:` field names which image `build-and-copy.sh` must produce (`vllm-node`, or
`vllm-node-tf5` for the transformers≥5 build). See
[`docs/benchmark/reproduce-pipeline.md`](../docs/benchmark/reproduce-pipeline.md).
