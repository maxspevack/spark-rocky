# The software stack, the delta vs DGX OS, and why the comparison is controlled

This is the one doc for "what runs where, what we changed, and why the benchmark comparison is honest." It
answers two questions that recur:
1. *"Did I just see `PyTorch not found`? Are we missing software?"* — No (see below).
2. *"You changed the OS — how is comparing to a DGX-OS number fair?"* — Because everything the benchmark
   executes lives inside a container we did **not** change; only the host below it differs.

## There are THREE software environments, not one

Conflating them is what makes `PyTorch not found` look alarming. They exist on purpose.

| | Environment | Where it runs | Role | PyTorch? |
|---|---|---|---|---|
| **1** | **Host** | bare metal | the layer **we swapped** (the RPM stack) | **No — by design** |
| **2** | **Serving container** (`vllm-node*`) | Docker, on the host | the **AI stack** that runs the model on the GPU (**held constant**) | **Yes — torch 2.11.0+cu130** |
| **3** | **Benchmark client** `llama-benchy` | host, ephemeral `uvx` venv | sends HTTP, counts tokens/sec | **No — and shouldn't** |

Verified inventory (2026-07-23, on the bare-metal box — the `6.18.39-clk` boot: doctor PASS, dmesg
gate PASS, vLLM serve-gate GATE-PASS):

```
ENV 1 — HOST (ours, the swapped layer)
  OS                       Rocky Linux 10.2 (Red Quartz)
  kernel                   6.18.39-clk  CIQ Linux Kernel (CLK), 4k pages, zero patches carried here  (rpm-installed, #59; the released image ships it too since spark-rocky-live-20260723; parity benched on stock 6.18.34/4k + CLK 6.18.38-clk/4k (#61). 64k reverted 2026-07-17 — serve regression #65)
  GPU driver               610.43.03 open module, WE built it            (the shipped driver; parity was benched on 610.43.02)
  platform firmware        NVIDIA's latest, via public fwupd/LVFS      (see build.md → Firmware)
  docker                   29.6.1 ; nvidia-container-toolkit 1.19.1
  CUDA toolkit (host)      13.0      used to BUILD the driver; not used to serve
  python torch?            NOT INSTALLED   ← correct; models don't run on the host

ENV 2 — SERVING CONTAINER vllm-node* (constant, the AI stack)
  torch 2.11.0+cu130 ; vLLM 0.22.1rc1.dev330+g6deb05e0e (built 2026-06-10) ; transformers 5.11.0
  flashinfer 0.6.13 ; CUDA runtime 13.0 (inside the image)

ENV 3 — BENCHMARK CLIENT llama-benchy (host, uvx, pinned 0.3.8)
  transformers: yes (to tokenize) ; torch: no  ← THIS is the "PyTorch not found" line
```

**Why `PyTorch not found` is correct.** `llama-benchy` is a load generator: it uses `transformers` to tokenize
prompts to exact token counts, then POSTs to the OpenAI-compatible `/v1` endpoint and times the stream. It
never loads weights, so it has no reason to install torch. The notice is `transformers` importing without
torch — reflexive, not an error. The model runs in ENV 2 (torch 2.11.0+cu130). Putting torch in the client
would be the actual mistake.

## The data path (follow one token)

```
  [ENV 3 host]  llama-benchy ──HTTP /v1──► [ENV 2 container] vLLM ─► flashinfer ─► torch ─► libcudart(13.0)
  ════════ container boundary; nvidia-container-toolkit injects the HOST libcuda ════════
                                          libcuda.so 610.43.03   (driver API — [ENV 1 host])
                                          nvidia.ko  610.43.03   (open kernel module — [ENV 1 host])
                                                  GB10 Grace Blackwell (silicon)
```

The seam that matters: the container ships the CUDA **runtime** (13.0) + PyTorch, but uses **our host driver's**
`libcuda.so` (610.43.03), injected at container start. A driver API is forward-compatible with equal-or-older
CUDA runtimes — 610 supports CUDA 13.0 — so the container runs unmodified on our self-built driver. Stock DGX
OS shipped driver 580.159.03 (also CUDA 13.0); both satisfy the container, which is why the swap is invisible
to the workload.

## The delta vs stock DGX OS — layer by layer

Everything we changed is **below** the container boundary (the host). Everything the benchmark executes is
**inside** it (held constant).

| Layer | Stock DGX OS (baseline) | Our spark-rocky | Verdict |
|---|---|---|---|
| **GPU silicon** | GB10 (sm_121), 121 GB unified | *same* | **CONSTANT** — the leaderboard is keyed to "DGX Spark" |
| **OS userspace** | Ubuntu 24.04.4 LTS | **Rocky Linux 10.2** | **OURS** |
| **Kernel** | `6.17.0-1021-nvidia` (vendored, NVIDIA-patched, gcc 13.3.0) | **CIQ Linux Kernel `6.18.39-clk`, zero patches carried here, 4k pages** (gcc 14.3.1; the public GPL `ctrliq/kernel-src-tree`, commit-pinned) — parity benched on stock `6.18.34`/4k; stock kernel.org stays the A/B knob. 64k reverted (#65) | **OURS** — vendor kernel → a public, pinnable 6.18 tree |
| **GPU kernel driver** | open `580.159.03` (NVIDIA-built) | **open `610.43.03`, WE built** (in `rockylinux:10`, against the stock tree, zero source patches) — parity benched on `610.43.02` | **OURS** — both *open*; our delta is version + that we built it against a stock kernel |
| **Driver userspace** (`libcuda.so`) | 580.159.03 | **610.43.03** (host; injected into the container) | **OURS** |
| **Platform firmware** | NVIDIA, via DGX OS OTA | **NVIDIA's latest, via public fwupd/LVFS** | **CONSTANT** — same firmware, different delivery path (no DGX OS needed) |
| **Container runtime** | docker + toolkit (Ubuntu pkgs) | docker + toolkit (Rocky pkgs) | **OURS, functionally equivalent** |
| ═══ container boundary ═══ | | | |
| **CUDA runtime / PyTorch / flashinfer / vLLM / model / recipe / benchmark tool** | in the image | *same image, same Dockerfile, same recipe* | **CONSTANT** — built from the upstream project's own Dockerfile |

## The single uncontrolled variable

spark-arena does **not** pin a vLLM version: `vllm-node` compiles whatever vLLM is current at image-build time.
Our image built vLLM dated 2026-06-10; entries were submitted earlier (the Qwen FP8 entry 2026-03-03). That
date gap is the one uncontrolled variable inside the "constant" stack — a *runtime* difference, not an
OS/kernel/driver one. We name it on every receipt and match the recipe's `container:` tag to minimize it.

## What this proves — and what it does not

- **Proves:** replacing the entire host — Ubuntu → Rocky 10.2, vendor `6.17-nvidia` → an unmodified public
  6.18 tree (CLK the shipped default, stock kernel.org the A/B; the June receipts ran on stock, the #61
  receipt on CLK — zero patches either way), NVIDIA-built `580` → self-built open `610` — is **transparent
  to the workload**. The same
  container + recipe + tool land the published numbers on the community's own scoreboard. Across **three
  full-matrix** models the **median is parity (0.96–1.05×)**, re-proven on the current pinned runtime at
  1.010× — and on the current NVFP4+MTP meta the host lands in the community band, with every point of
  movement attributable to serving config, not the host — see [`scoreboard.md`](../benchmark/scoreboard.md).
- **Does NOT prove "Rocky is faster."** Per-axis deltas track vLLM-date drift, not the host swap. A clean
  speed claim would require pinning the entry-date vLLM, which the leaderboard does not do.

## Confidence (the three lenses)

- **Mechanism, not promise.** We don't ask anyone to *believe* Rocky ≈ Ubuntu for this workload — we run the
  byte-identical workload container on a different host and reproduce the numbers on the independent scoreboard.
  The container boundary is the control; the leaderboard is the witness.
- **Proven vs inferred.** Proven: the three environments as inventoried; the host carries zero kernel/driver
  source patches; the workload container is the upstream artifact; firmware is NVIDIA's latest. Inferred: that
  a given leaderboard submitter ran stock DGX OS (the population is "DGX Spark"; their exact driver isn't
  recorded). The claim we stand behind is exact: *on identical hardware running an identical AI-stack container,
  swapping the host to the RPM stack reproduces the published single-host numbers* — not "faster."
