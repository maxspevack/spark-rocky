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
`container:` tag the entry was produced with. Commit it under `recipes/` (top level — verbatim
mirrors are never served by the registry tiers) and add its row to `recipes/MIRRORS.tsv`; CI
enforces the root-integrity ledger.

## Step 3 — serve it (spark-vllm-docker), single host

```bash
cd /root/spark-vllm-docker
# Serving image, two generations (config/serving-images.env, #71):
#   gen 1 (behind the June receipts): local builds — ./build-and-copy.sh [--tf5] -> vllm-node[-tf5]
#   gen 2 (current, preferred): pull the PINNED permanent mirror tag instead of building —
#     docker pull ghcr.io/spark-arena/dgx-vllm-eugr-nightly@$SERVING_IMAGE_DIGEST
#     and run a recipe VARIANT whose container: names that tag (recipes/*-<TAG>.yaml; receipt-backed
#     variants promote into recipes/spark-rocky/ per recipes/README.md).
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
v2 profile: the **sparkrun section at the end of this page**.)

For the **full matrix** — the ~104-cell sweep the parity claim rests on (depth × prefill × decode ×
concurrency) — do not retype the params; run the canonical script. It carries the `llama-benchy` version pin
and encodes the exact sweep, so every reproduction and every regression-vs-self run measures the same surface:

```bash
scripts/run-benchmark-matrix.sh 8000 <HF/path> result.csv
```

## Step 5 — compare + record

Commit a receipt in `receipts/` (see `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt` for the format): host stack,
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

## sparkrun on this host — the board's own harness, validated

[sparkrun](https://github.com/spark-arena/sparkrun) is how spark-arena entries are actually
produced: registry recipes + the official benchmark profile + (for submitters) `arena benchmark`
upload. This section records the validated path for running it **on this stack** (Rocky 10.2 +
CLK kernel + open driver), alongside — not replacing — the receipt-grade flow above.
Validation evidence: #72.

### Install (no wizard needed)

```bash
# Pinned install + post-install verification; the pin lives in config/serving-images.env
# (SPARKRUN_VERSION). Never hand-copy a version number into this doc — the previous form of
# this block rotted exactly that way (a prose install line is a pin in disguise).
scripts/install-sparkrun.sh          # from the repo root
sparkrun update              # fetches the recipe registries (official/community/eugr/...)
```

The `sparkrun setup` wizard (cluster/SSH-mesh/sudoers/earlyoom) is **not required** for
single-node use, and its two apt-coupled helpers (`setup earlyoom`, `setup system-update`) are
the only Ubuntu-assuming corners found — skip them here; earlyoom is `dnf install earlyoom`
if ever wanted.

### Run the official board profile, single node

```bash
sparkrun benchmark <recipe> --hosts localhost --rootful \
  --profile @official/spark-arena-v2 --output results.yaml
```

Two host-compat divergences were hit on this stack (everything else ran unmodified):

- **`--hosts localhost` is required.** Without the setup wizard there are no configured default
  hosts, and `sparkrun benchmark` errors out (`No hosts specified`) — the localhost fast path
  exists in the launcher but is not the CLI default.
- **`--rootful` stays, by choice.** [sparkrun#225](https://github.com/spark-arena/sparkrun/issues/225)
  (rootless adds `--device /dev/infiniband` unconditionally; dies on this mlx5-blacklisted stack)
  is fixed in the release line we now run (`SPARKRUN_VERSION` in `config/serving-images.env`) —
  but its rootless GPU path needs CDI specs on
  wizard-free hosts (`unresolvable CDI devices`; `nvidia-ctk cdi generate` would provision them).
  `--rootful` sidesteps both and is what every receipt on this host ran with; keeping it.
- **If the recipe sets its served name inline** (in the `command:` string rather than as a
  `served_model_name:` defaults key), llama-benchy gets the HF path instead, 404s on warmup, and
  the run dies at task 1 with an empty table. Override per-run: `-b served_model_name=<name>`.
  Not host-specific — any sparkrun user benchmarking such a recipe hits it.

- `@official/spark-arena-v2` is the leaderboard's run-rule surface: depths
  {0, 4k, 8k, 16k, 32k, 64k, 100k} × pp2048 × tg128 × concurrency {1, 2, 5, 10},
  prefix caching on, runs=3, heat-aware cell order. `arena benchmark` (the submission path)
  hard-codes this same profile.
- Cells map 1:1 to leaderboard columns (`tg128 @ d<depth> (c<N>)` etc.), so results are
  board-comparable by construction.

### 35B-class models: use the two-step (the one-shot's readiness wait is too short)

`sparkrun benchmark`'s server-readiness wait (~5 min) is shorter than a 35B's legitimate startup on
this box (~7 min: weight load + FlashInfer autotune; a cold `torch.compile` first-serve has run
~6.5 min on its own) — the one-shot gives up and tears down a healthy loading serve. Two-step instead:

```bash
sparkrun run <recipe> --hosts localhost --rootful --image <pinned tag> --no-follow
until curl -sf http://localhost:8000/v1/models >/dev/null; do sleep 5; done    # cap it yourself (~18 min)
rm -rf ~/.cache/sparkrun/benchmarks    # resume-state — see below
sparkrun benchmark <recipe> --hosts localhost --rootful --image <pinned tag> \
  --profile @official/spark-arena-v2 --skip-run --output results.yaml
docker rm -f $(docker ps -aq --filter name=sparkrun)    # teardown — see below
```

Three sparkrun defects this flow routes around (hit live on 0.2.40, 2026-07-25, record on #74;
status re-verified on the 0.3.0-alpha default, 2026-07-27):

- **Resume-state poisons repeat measurements — the trap.** `~/.cache/sparkrun/benchmarks/<id>/` keys
  on (model, profile), NOT recipe content, and a repeat run of the same model+profile **returns the
  prior run's numbers wholesale** — no traffic ever reaches the server. On 0.2.40, `--fresh` did
  not clear complete state; the 0.3.0-alpha fixes the `--fresh` path (explicit state deletion) but
  the key still excludes recipe content BY DESIGN, so a repeat without `--fresh` still silently
  re-emits prior results. Detection: results identical to a prior run at full float precision,
  plus zero `SpecDecoding`/request activity in the serve log. Rule unchanged: clear the state dir
  before every measured run (the snippet above does).
- **Teardown leaks.** `sparkrun stop --all --hosts localhost` claims success and exits 0 while the
  containers keep running (it wraps the stop in ssh-to-self, which fails on wizard-free hosts).
  Persists in the 0.3.0-alpha (verified 2026-07-27 — it now logs the SSH failure and still reports
  "Stopped"): [#229](https://github.com/spark-arena/sparkrun/issues/229) /
  [PR #231](https://github.com/spark-arena/sparkrun/pull/231). `docker rm -f` the `sparkrun*`
  containers between runs and verify `docker ps -aq | wc -l` → 0.
- **The serve log lives inside the container.** With `run --no-follow`, vLLM output goes to
  `/tmp/sparkrun_serve.log` in-container (`docker logs` shows only the NGC banner). `docker cp` it out
  **before** teardown — it is the only place MTP engagement (`SpecDecoding metrics`) and engine-init
  root causes can be read.

`--skip-run` also separates serve problems from measurement problems when diagnosing either.

### Sustained sweeps: the chunked receipt protocol (`scripts/receipt-chunked.sh`)

A ~55-minute continuous v2 sweep thermally saturates a desk Spark ([`scoreboard.md`](scoreboard.md)
ch. 3), so a full official matrix run as one shot gets discarded THROTTLED. The runner behind both
frontier receipts encodes the fix: the same 28 official cells in **segments**, a **cool-to-≤55°C
gap** between segments, per-segment `templog` trace + `check-throttle.sh` verdict (any THROTTLED
segment re-runs from a cooled start), and the sparkrun resume-state dir cleared per segment so every
number is freshly measured. Headline cells then run N≥5 on a fresh serve. First validated in full
2026-07-25: 11/11 segments CLEAN on the cells two sustained attempts had failed. Read the script's
header for invocation; it composes the same primitives this page documents (two-step serve, teardown
by `docker rm -f`, pinned image tag).

### Pinning the container (do not float on `latest`)

Registry recipes name `ghcr.io/spark-arena/dgx-vllm-eugr-nightly[-tf5]:latest`. Docker's
`missing` pull policy means a **local** tag by that name wins — so pin by locally tagging the
generation-2 image from [`config/serving-images.env`](../../config/serving-images.env) over the
`latest` name before benchmarking:

```bash
docker tag ghcr.io/spark-arena/dgx-vllm-eugr-nightly:<SERVING_IMAGE_TAG> \
           ghcr.io/spark-arena/dgx-vllm-eugr-nightly:latest
docker tag ghcr.io/spark-arena/dgx-vllm-eugr-nightly:<SERVING_IMAGE_TAG> \
           ghcr.io/spark-arena/dgx-vllm-eugr-nightly-tf5:latest
```

(`-tf5` is upstream's deprecated alias of `-nightly` — identical content by their own
deprecation note — so the local tag is semantically truthful.) Record the tag actually served
in any result you keep.

### Box hygiene (same sensors as the receipt flow)

- Reboot to a clean pool before a serve series (driver leaks GPU memory on container stop).
- `sync && echo 3 > /proc/sys/vm/drop_caches` before serving — on unified memory,
  `cudaMemGetInfo` sees `MemFree`, and page cache from a prior image pull starves vLLM's
  startup check (hit live 2026-07-24; the serve-gate now does this itself).
- Never two concurrent `docker run --gpus`.

### Submission (for reference — deliberately not exercised)

`sparkrun arena login` (account is admin-approved) → `sparkrun arena benchmark <recipe>` →
uploads recipe + logs + metadata to the board's storage. Mechanism confirmed from source (#7);
whether/when to create an account is a maintainer decision, not part of this validation.
`arena benchmark --local-test` exists for a simulated-upload smoke run.

### When to use which harness

| | `reproduce-pipeline.md` (spark-vllm-docker + matrix script) | sparkrun + v2 profile |
|---|---|---|
| Purpose | receipt-grade reproduction/regression (N≥5, templog, throttle detector) | board-comparable cells, the community's exact flow |
| Matrix | the canonical ~104-cell sweep | the official 28-cell × 3-run profile |
| Use for | parity claims, drift reads, receipts | pre-submission runs, cross-checking our numbers against board methodology |
