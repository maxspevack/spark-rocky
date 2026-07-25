# recipes/ — serve configs, pulled verbatim from spark-arena

These are **not ours.** Each is the exact recipe spark-arena publishes for a leaderboard entry, pulled
byte-for-byte from `https://spark-arena.com/api/recipes/<permalink>/raw` and committed unchanged. They define
how `spark-vllm-docker`'s `run-recipe.sh` serves the model (the `vllm serve` command, flags, env, mods, and
the container tag). Reproducing an entry means running *its* recipe, not one we tuned.

| File | Entry | Container | Notes |
|---|---|---|---|
| `qwen3.5-35b-a3b-fp8-arena.yaml` | Qwen3.5-35B-A3B-FP8 (`28879af7`) | `vllm-node-tf5` | flashinfer, fp8 KV, `mods/fix-qwen3.5-autoround` |
| `qwen3.5-0.8b-arena.yaml` | Qwen3.5-0.8B (`sub1777633319098`) | `vllm-node` | public model, no token |
| `gemma-3-1b-it-arena.yaml` | gemma-3-1b-it (`sub1779455882567`) | `vllm-node-tf5` | HF-gated (token required to download) |
| `gpt-oss-120b-arena.yaml` | gpt-oss-120b | `vllm-node-mxfp4` | MXFP4 `--mxfp4-backend CUTLASS`, fp8 KV, flashinfer, ray |

**One deliberate exception to "not ours" — pinned variants**, suffixed with a dgx-vllm mirror tag: the
same recipe byte-for-byte except `container:` names the permanent gen-2 tag (and `description:` says so).
Same serve, pinned runtime (#71).

| File | Derived from | Container |
|---|---|---|
| `qwen3.5-0.8b-arena-2026072302.yaml` | `qwen3.5-0.8b-arena.yaml` (one-line container delta, verified) | `ghcr.io/spark-arena/dgx-vllm-eugr-nightly:2026072302` — behind `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt` |

**And one deliberate config of ours — the #74 winner:**

| File | Derivation | Container |
|---|---|---|
| `qwen3.6-35b-a3b-nvfp4-mtp-nst3-2026072302.yaml` | The official `qwen3.6-35b-a3b-fp8-mtp` shape with two probe-isolated swaps (2026-07-25, #74): the `nvidia/` ModelOpt NVFP4 checkpoint (+48% vs the compressed-tensors quant swap) and `num_speculative_tokens` 2→3 (+19%). Fresh-serve `tg128 (c1)` 109.1 — in the community band. | pinned gen-2 tag |

## Add a recipe

```bash
../data/fetch.sh <sub-id>      # writes recipe-<sub-id>.yaml; commit it here, renamed per the entry
```

The `container:` field names which image `build-and-copy.sh` must produce (`vllm-node`, or `vllm-node-tf5`
for the transformers≥5 build). See [`docs/benchmark/reproduce-pipeline.md`](../docs/benchmark/reproduce-pipeline.md).
