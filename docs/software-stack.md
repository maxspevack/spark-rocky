# The complete software stack — and why "PyTorch not found" is correct, not a gap

> A reviewer (correctly) asked: *"Did I just see PyTorch not found? Are we missing software?"*
> No. That line comes from the **benchmark client**, which deliberately has no PyTorch. This doc maps
> every piece of software in play, where it runs, and why — so the question can't recur, and so the
> control in our experiment is legible.

## There are THREE environments, not one

The single most important thing to understand: this is not one machine running one pile of software. It
is **three separate software environments**, and they exist on purpose. Conflating them is what makes
"PyTorch not found" look alarming.

| | Environment | Where it runs | Role | Has PyTorch? |
|---|---|---|---|---|
| **1** | **Host** | bare metal | the layer **we swapped** (CIQ stack) | **No — by design** |
| **2** | **Serving container** `vllm-node-tf5` | Docker, on the host | the **AI stack** that runs the model on the GPU (**held constant**) | **Yes — torch 2.11.0+cu130** |
| **3** | **Benchmark client** `llama-benchy` | host, ephemeral `uvx` venv | sends HTTP requests, counts tokens/sec | **No — and shouldn't** |

Verified inventory (2026-06-10, on the box):

```
ENV 1 — HOST (ours, the swapped layer)
  OS                     Rocky Linux 10.2 (Red Quartz)
  kernel                 6.18.34            upstream mainline, ZERO patches
  GPU driver             610.43.02          open module, WE built it
  docker                 29.5.3
  nvidia-container-toolkit 1.19.1
  CUDA toolkit (host)    13.0   (used to BUILD the driver; not used to serve)
  python torch?          NOT INSTALLED      ← correct; models don't run on the host

ENV 2 — SERVING CONTAINER vllm-node-tf5 (constant, the AI stack)
  torch                  2.11.0+cu130       built for CUDA 13.0
  vLLM                   0.22.1rc1.dev330+g6deb05e0e  (built 2026-06-10)
  transformers           5.11.0             (the "tf5" build = transformers >= 5)
  flashinfer             0.6.13
  CUDA runtime           13.0   (inside the image)

ENV 3 — BENCHMARK CLIENT llama-benchy (host, uvx)
  has transformers       True   (to tokenize the prompt text)
  has torch              False  ← THIS is the "PyTorch not found" line
```

## Why the warning is correct

`llama-benchy` is a **load generator**, not an inference engine. It (a) uses `transformers` to tokenize
prompt text so it can hit exact token counts, and (b) POSTs to the OpenAI-compatible `/v1` endpoint and
times the token stream. It never loads model weights, so it has no reason to install PyTorch. When
`transformers` imports without torch present, it prints `PyTorch was not found. Models won't be
available...` — a reflexive notice, not an error. **The model runs in ENV 2, which has torch 2.11.0+cu130.**
Putting PyTorch in the benchmark client would be the actual mistake — bloat that does nothing.

## The data path (follow one token)

```
  [ENV 3 host]  llama-benchy  ──HTTP POST /v1/completions──►  [ENV 2 container]  vLLM
                                                                      │
                                          torch 2.11 + flashinfer 0.6.13  (Python, container)
                                                                      │
                                              CUDA runtime 13.0  (libcudart, container)
                                                                      │
              ══════ container boundary; nvidia-container-toolkit injects host libcuda ══════
                                                                      │
                                          libcuda.so 610.43.02   (driver API — [ENV 1 host])
                                                                      │
                                          nvidia.ko 610.43.02    (kernel module — [ENV 1 host])
                                                                      │
                                                  GB10 Grace Blackwell (silicon)
```

The seam that matters: the container ships the CUDA **runtime** (13.0) and PyTorch, but uses **our host
driver's** `libcuda.so` (610.43.02), injected at container start by the nvidia-container-toolkit. A driver
API is forward-compatible with equal-or-older CUDA runtimes — 610 supports CUDA 13.0 — so the container's
CUDA-13 stack runs unmodified on our self-built driver. Stock DGX OS shipped driver 580.159.03 (also
CUDA 13.0); both satisfy the container, which is exactly why the swap is invisible to the workload.

## What this means for the experiment (the three lenses)

**The control — and its one leak (Matthew).** The load-bearing assumption is: *the AI stack is
identical-by-construction across hosts, because it lives entirely inside a container built from the
upstream project's own Dockerfile.* That is what licenses "we changed only the host." It holds for
torch, CUDA, flashinfer, transformers, the model, the recipe, and the benchmark tool. It **leaks in
exactly one place**: the Dockerfile compiles *latest* vLLM at build time, so the vLLM version drifts with
build date. Our image built vLLM dated 2026-06-10; the Qwen entry was submitted 2026-03-03. That ~3-month
drift is the one uncontrolled variable, and we name it on every result rather than burying it.

**The mechanism, not a promise (Max).** We do not ask anyone to *believe* Rocky is equivalent to Ubuntu
for this workload. We take the byte-identical workload container and run it on a different host — Rocky
10.2 + stock upstream kernel + self-built open driver, zero patches — and reproduce the published numbers
on the community's own scoreboard. The container boundary is the experimental control; the leaderboard is
the independent witness. Ship: the reproduction. Shield: zero host patches (nothing to carry, nothing to
rot). Sensor: the vLLM-date drift, watched on every row.

**Confidence as contract (Peter).** Proven: the three environments are as inventoried above; the host
carries zero kernel/driver source patches; the workload container is the upstream artifact. In progress:
the full-matrix reproduction (the canonical `llama-benchy` sweep) — a single cell is not a reproduction.
Inferred, not proven: the specific leaderboard submitter ran stock DGX OS (the spark-arena population is
"DGX Spark"); their exact driver is not recorded. The claim we will stand behind is narrow and exact:
*on identical hardware running an identical AI-stack container, swapping the host to the CIQ-shaped stack
(Rocky + upstream kernel + open driver, zero patches) reproduces the published single-host numbers* —
not "Rocky is faster."
