# Reproduce any spark-arena single-host entry — the pipeline

This is the end-to-end method this repo uses. It is deterministic and credential-free: a third party can
take any leaderboard entry and reproduce it on the host stack, without a spark-arena or HuggingFace account.

## The data model (how spark-arena stores entries)

spark-arena.com is a client-rendered app backed by **public Firebase/Firestore** (project `spark-arena`).
The leaderboard view loads a pre-aggregated document keyed by **submission IDs** (`sub<epoch_ms>`), which is
what our snapshot (`data/spark-arena-snapshot-*.json`, `entriesByTest`) captured. The per-entry *detail pages*
use a different identifier — a **recipe permalink UUID**. The two are linked inside each benchmark document:

```
snapshot entry .benchmarkId  ==  Firestore  benchmarks/<sub-ID>  (doc key)
                                              └── field recipePermalinkId = <UUID>
                                                   └── https://spark-arena.com/api/recipes/<UUID>/raw
```

The `benchmarks/<sub-ID>` document also carries the full recipe inline (`command`, `defaults`, `env`, `mods`,
`container`, `fullRecipe`) and the published results (`tokensPerSec`, `tests`, `tokensPerSecStdDev`). The
Firestore `benchmarks` collection is world-readable; `submissions`/`recipes`/`leaderboard` are not (403) —
we never need them.

## Step 1 — map a snapshot entry to its recipe permalink

Firestore REST (public read; the apiKey below is the site's own public web key, embedded in its JS bundle):

```bash
KEY="AIzaSyDy4gDrfBr0LnXdN7N2CT7IUq7oIQCBrpI"
SUB="sub1772533296511"          # = snapshot entry .benchmarkId for the target
curl -s "https://firestore.googleapis.com/v1/projects/spark-arena/databases/(default)/documents/benchmarks/$SUB?key=$KEY" \
  | grep -A1 recipePermalinkId
# -> stringValue: 28879af7-99f6-49bf-ae89-d6ceeb7eb229
```

## Step 2 — pull the exact recipe

```bash
UUID="28879af7-99f6-49bf-ae89-d6ceeb7eb229"
curl -fsSL -o recipes/<name>.yaml "https://spark-arena.com/api/recipes/$UUID/raw"
```

This yaml is the authoritative reproducer — the exact `vllm serve` command, defaults, env, mods, and the
`container:` tag the entry was produced with. Commit it under `recipes/`.

## Step 3 — serve it (spark-vllm-docker), single host

```bash
cd /root/spark-vllm-docker
# Serving image, two generations (config/serving-images.env, #71):
#   gen 1 (behind the June receipts): local builds — ./build-and-copy.sh [--tf5] -> vllm-node[-tf5]
#   gen 2 (current, preferred): pull the PINNED permanent mirror tag instead of building —
#     docker pull ghcr.io/spark-arena/dgx-vllm-eugr-nightly@$SERVING_IMAGE_DIGEST
#     and run a recipe VARIANT whose container: names that tag (recipes/*-<TAG>.yaml).
#     Upstream's --tf5 lineage collapsed 2026-07 — one gen-2 image serves both.
./run-recipe.sh <name> --solo -d     # applies serve flags + mods + env from the recipe; host networking
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/health)" = 200 ]; do sleep 5; done
```

## Step 4 — measure (canonical tool)

spark-vllm-docker's README §9 names **llama-benchy** as the benchmark tool. The leaderboard test
`tg128 (c1)` = token-generation 128, concurrency 1. Run N≥5 for a spread:

```bash
uvx llama-benchy --base-url http://localhost:8000/v1 --model <HF/path> \
  --pp 2048 --tg 128 --concurrency 1 --runs 5
```

(The org's official runner is also validated on this host — install, gotchas, and the official
v2 profile: [`sparkrun-harness.md`](sparkrun-harness.md).)

For the **full matrix** — the ~104-cell sweep the parity claim rests on (depth × prefill × decode ×
concurrency) — do not retype the params; run the canonical script. It pins `llama-benchy==0.3.8` and encodes
the exact sweep, so every reproduction and every regression-vs-self run measures the same surface:

```bash
scripts/run-benchmark-matrix.sh 8000 <HF/path> result.csv
```

## Step 5 — compare + record

Commit a receipt in `receipts/` (see `reproduce-LFM2.5-350M-2026-06-10.txt` for the format): host stack,
benchmark stack versions, the exact recipe, the exact commands, raw N≥5 output, the published number, and
every confound. The standing confound on every cross-date entry: **spark-arena does not pin a vLLM version**
(spark-vllm-docker builds latest vLLM at image-build time), so a date gap between our image and the entry is
a real runtime-version difference. **Our side is closed (#71):** pin the gen-2 dated mirror tag and the
receipt names a byte-identical runtime; what remains is the entry's side — state it.

## Sensors / gotchas

- **Driver leaks GPU memory on container stop/crash** (open 610). Reboot to a clean pool before each serve
  series; `free -g` should read ~3u/118a before serving.
- **Page cache starves CUDA's free-memory read** (unified memory: `cudaMemGetInfo` sees `MemFree`, not
  `MemAvailable`). A big `docker pull` right before serving fails vLLM's startup check while `free -g`
  shows plenty available — `sync && echo 3 > /proc/sys/vm/drop_caches` first (the serve-gate does this
  itself since 2026-07-24; hit live during #71).
- **HuggingFace token: not required** for public models (verify `curl -s -o /dev/null -w '%{http_code}'
  https://huggingface.co/api/models/<repo>` → 200). Gated models would need a token; none of our targets are.
- **gpu-memory-utilization is the total unified-memory budget** (fraction × 121 GB = model + KV). Too low →
  "No available memory for the cache blocks"; the recipe's value is authoritative — don't hand-tune it.
- **Never start a second GPU container while one is initializing.** The nvidia-container-toolkit serializes
  GPU init; two concurrent `docker run --gpus` calls deadlock. (Cost one stuck launch on 2026-06-10.)
- **The full matrix is long on big models.** `llama-benchy --save-result` writes the CSV only at the end, and
  `nohup` block-buffers stdout — judge progress from the container's request log / `nvidia-smi`, not the
  stdout cell counter.
