# Scoreboard — single-host `tg128 (c1)`, spark-arena vs spark-rocky

Targets we reproduce on the zero-patch stack (Rocky 10.2 + 6.18.34 + open 610), newest snapshot `data/spark-arena-snapshot-2026-06-10.json`. Each row maps to its recipe via [`docs/reproduce-pipeline.md`](reproduce-pipeline.md) (`benchmarkId` → Firestore → recipe permalink).

| # | model | published t/s | runtime | recipe | ours t/s | status | notes |
|---|---|---|---|---|---|---|---|
| 1 | LFM2.5-350M | 222.8 | vLLM | spark-vllm-docker | 246.0 ±0.3 | **reproduced (+10.4%)** | stock `vllm-node`; receipt committed |
| 2 | Qwen3.6-35B-A3B-NVFP4 | 218.8 | Atlas | sparkrun | — | pending | needs `sparkrun` + Atlas runtime (deferred dep) |
| 3 | Qwen3.6-35B-A3B-FP8 | 172.0 | Atlas | sparkrun | — | pending | needs `sparkrun` + Atlas runtime (deferred dep) |
| 4 | Qwen3.5-0.8B | 121.2 | vLLM | spark-vllm-docker | — | pending |  |
| 5 | Qwen3.6-35B-A3B-PrismaQuant-4.75bit-vllm | 95.1 | vLLM | spark-vllm-docker | — | pending |  |
| 6 | Qwen3.6-35B-A3B-int4-AutoRound | 92.3 | vLLM | spark-vllm-docker | — | pending |  |
| 7 | gemma-3-1b-it | 91.0 | vLLM | spark-vllm-docker | — | pending |  |
| 8 | Holo-3.1-35B-A3B-NVFP4 | 75.4 | vLLM | spark-vllm-docker | — | pending |  |
| 9 | Qwen3-Coder-Next-int4-AutoRound | 73.3 | vLLM | spark-vllm-docker | — | pending |  |
| 10 | gemma-4-E2B-it | 67.1 | vLLM | spark-vllm-docker | — | pending |  |
| 11 | NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4 | 62.1 | vLLM | spark-vllm-docker | — | pending |  |
| 12 | gpt-oss-120b | 58.8 | vLLM | spark-vllm-docker | — | pending |  |
| 13 | Nemotron-Cascade-2-30B-A3B-NVFP4 | 57.8 | vLLM | sparkrun | — | pending | needs `sparkrun` + Atlas runtime (deferred dep) |
| 14 | Nemotron-3-Nano-Omni-30B-A3B-Reasoning-NVFP4 | 57.0 | vLLM | spark-vllm-docker | — | pending |  |
| 15 | Huihui-Qwen3.6-35B-A3B-Claude-4.6-Opus-abliterated-FP8 | 52.8 | vLLM | spark-vllm-docker | — | pending |  |

**Confound on every cross-date row:** spark-arena does not pin vLLM; our image's build date vs the entry's submission date is a real runtime-version delta. Match the recipe `container:` tag to minimize it.
