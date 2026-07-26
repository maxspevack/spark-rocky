# spark-arena published recipe — the board-best single-node Nemotron-3-Super entry (#73 evidence)
#
# Entry: sub1778644062716 (23.71 t/s tg128(c1), cluster=1) · permalink ff09e374-9866-421d-a887-20fd0c770c2f
# Fetched 2026-07-25 via https://spark-arena.com/api/recipes/ff09e374-9866-421d-a887-20fd0c770c2f/raw
# Verbatim below — note the speculative-config line: MTP is ON at nst=1 in this entry.

model: nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
defaults:
  max_model_len: 131072
  port: 8000
  max_num_seqs: 4
  host: 0.0.0.0
  gpu_memory_utilization: 0.75
  tensor_parallel: 1
  max_num_batched_tokens: 16384
command: |
  vllm serve nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 \
    --served-model-name nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 \
    --tensor-parallel-size {tensor_parallel} \
    --port {port} --host {host} \
    --max-model-len {max_model_len} \
    --max-num-seqs {max_num_seqs} \
    --max-num-batched-tokens {max_num_batched_tokens} \
    --gpu-memory-utilization {gpu_memory_utilization} \
    --quantization fp4 \
    --moe-backend marlin \
    --kv-cache-dtype fp8 \
    --mamba-ssm-cache-dtype float32 \
    --async-scheduling \
    --enable-chunked-prefill \
    --reasoning-parser nemotron_v3 \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    --speculative-config '{"method":"mtp","num_speculative_tokens":1,"moe_backend":"triton"}' \
    --trust-remote-code
container: vllm/vllm-openai@sha256:3dbe092ec5b2cef63b6104d33fa75d6ce53a7870962529ada69f78bbbc38e776
recipe_version: '1'
name: Nemotron-3-Super-NVFP4-MTP
solo_only: true
env:
  VLLM_ALLOW_LONG_MAX_MODEL_LEN: '1'
  VLLM_USE_FLASHINFER_MOE_FP4: '0'
  VLLM_NVFP4_GEMM_BACKEND: marlin
description: vLLM serving Nemotron-3-Super-120B-A12B-NVFP4 on DGX Spark with MTP speculative decoding
cluster_only: false
