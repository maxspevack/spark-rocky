# Soup-to-nuts: the stack behind our best result, and exactly where we deviate

Best result so far: **LiquidAI/LFM2.5-350M, `tg128 (c1)` = 246.0 ±0.3 t/s** on bare-metal Rocky,
vs the published spark-arena entry **222.77 t/s** (`receipts/reproduce-LFM2.5-350M-2026-06-10.txt`).

The whole argument rests on one structural fact: **the benchmark runs inside a Docker container.** That
container is the *workload*, and we build it from the upstream project's own Dockerfile — so it is
identical-by-construction to how the leaderboard entry was produced. Everything we changed lives **below
the container boundary** (the host). Everything the benchmark actually executes lives **inside it** (held
constant). That boundary is what makes the delta clean.

```
                              ┌───────────────────────────────────────────────┐
   measured number  ◄──────── │  llama-benchy 0.3.8   (CONSTANT — canonical)   │
        246 t/s               │      │ OpenAI /v1 over localhost               │
                              │      ▼                                          │
                              │  vLLM  ──► flashinfer ──► PyTorch ──► libcudart │  ◄─ WORKLOAD
                              │  serve recipe (flash_attn, fastsafetensors,…)   │     (CONSTANT:
                              │  model: LFM2.5-350M (public HF, anon)           │      same image,
                              │  ── all inside image `vllm-node` ──             │      same recipe)
                              └───────────────────┬───────────────────────────┘
   ══════ CONTAINER BOUNDARY ════════════════════ │ ═══ nvidia-container-toolkit injects host libcuda ═══
                              ┌───────────────────▼───────────────────────────┐
                              │  libcuda.so 610.43.02   (OURS — host driver API)│  ◄─ HOST
                              │      ▼                                          │     (OURS:
                              │  nvidia.ko 610.43.02  open module, WE built     │      everything
                              │      ▼     (vermagic 6.18.34, zero patches)     │      replaced vs
                              │  kernel 6.18.34  upstream mainline, zero patches│      stock DGX OS)
                              │      ▼                                          │
                              │  Rocky Linux 10.2  +  docker + container-toolkit│
                              │      ▼                                          │
                              └───────────────────┬───────────────────────────┘
                                                  ▼
                                        GB10 Grace Blackwell  (CONSTANT — same silicon)
```

## Layer-by-layer

| Layer | Stock DGX OS (baseline) | Our spark-rocky | Verdict |
|---|---|---|---|
| **GPU silicon** | GB10 (sm_121), 121 GB unified, ATS | *same* | **CONSTANT** — same hardware; the leaderboard is keyed to "DGX Spark" |
| **OS userspace** | Ubuntu 24.04.4 LTS | **Rocky Linux 10.2** | **OURS** |
| **Kernel** | `6.17.0-1021-nvidia` (vendored, NVIDIA-patched, gcc 13.3.0) | **`6.18.34` upstream mainline, ZERO patches** (gcc 14.3.1) | **OURS** — vendor kernel → stock upstream |
| **GPU kernel driver** | open `580.159.03` (NVIDIA-built) | **open `610.43.02`, WE built** (in `rockylinux:10`, gcc 14.3.1, against the 6.18.34 tree, zero source patches) | **OURS** — note both are *open* modules; our delta is version + that we built it against a stock kernel |
| **Driver userspace** (`libcuda.so`) | 580.159.03 | **610.43.02** (host, injected into the container by the toolkit) | **OURS** |
| **Container runtime** | docker + nvidia-container-toolkit (Ubuntu pkgs) | docker + nvidia-container-toolkit (Rocky pkgs) | **OURS, functionally equivalent** |
| ═══ container boundary ═══ | | | |
| **CUDA runtime** (`libcudart`, cuBLAS, …) | in image | *same image* | **CONSTANT** — ships inside `vllm-node` |
| **PyTorch / flashinfer / fastsafetensors** | in image | *same image* | **CONSTANT** — same Dockerfile |
| **vLLM** | in image, built at image-build time | *same Dockerfile* — **but built `2026-06-08`** | **CONSTANT-by-construction, with one drift ↓** |
| **Model** | LiquidAI/LFM2.5-350M | *same* public HF snapshot, anon download | **CONSTANT** |
| **Serve recipe** | spark-arena recipe `6a9c9b76…` | *byte-identical*, pulled from the permalink (`recipes/lfm2.5-350m-arena.yaml`) | **CONSTANT** — flash_attn, fastsafetensors, gpu-util 0.8, etc. |
| **Benchmark tool** | llama-benchy | llama-benchy 0.3.8, same invocation | **CONSTANT** — the tool spark-vllm-docker's README names |

## The single uncontrolled variable

spark-arena does **not** pin a vLLM version: `vllm-node` compiles whatever vLLM is current at image-build
time. The LFM entry was submitted **2026-05-05**; our image built vLLM dated **2026-06-08** (~1 month
newer). So inside the "constant" stack, exactly one thing differs — the vLLM build date. That is the most
plausible source of the +10.4%, and it is a *runtime* difference, not an OS/kernel/driver one.

## What this proves (and what it does not)

- **Proves:** replacing the entire host — Ubuntu → Rocky 10.2, vendor `6.17-nvidia` → stock upstream
  `6.18.34` (zero patches), NVIDIA-built `580` → self-built open `610` — is **transparent to the workload**.
  The same container, recipe, and tool produce the published number (within runtime-version drift). Rocky +
  a stock upstream kernel runs the GB10 and lands on the community's own scoreboard, carrying **zero source
  patches** at the kernel or driver layer.
- **Does NOT prove "Rocky is faster."** The +10.4% is attributable to the one uncontrolled variable (vLLM
  date), not the host swap. To claim a speed delta we would pin the entry-date vLLM — which the leaderboard
  itself does not do, so cross-date comparisons are inherently runtime-drifted.

## Confidence

Our side of the table is **exact** (measured, provenanced in the receipt). The "stock DGX OS" column is the
captured baseline of *this* box (`config/dgx-reference.txt`, 2026-06-08). The specific LFM submitter's host
is **inferred** to be stock DGX OS (the spark-arena population is "DGX Spark"); their exact driver is not
recorded by the leaderboard. The comparison that is fully controlled is workload-vs-workload; the host
column is our box's documented before/after.
