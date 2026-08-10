# Verify a number yourself — reproduce any spark-arena single-host entry

Deterministic and account-light: a third party can take any leaderboard entry and reproduce it on
this stack without a spark-arena account; a HuggingFace account is needed only for gated models (of
our targets, only gemma-3-1b-it). Two harnesses — pick by what you need:

| | **Path A — sparkrun + the official profile** | **Path B — receipt-grade** |
|---|---|---|
| Purpose | board-comparable cells, the community's exact flow | a reproduction this repo would commit as a receipt |
| Matrix | the official 28-cell × 3-run v2 profile | the canonical ~104-cell sweep the parity claim rests on |
| Rigor | the board's run rules | N≥5 headline cells, 2-second thermal trace, post-hoc throttle verdict |
| Tooling | `sparkrun` (validated on this stack, #72) | `spark-vllm-docker` + `scripts/run-benchmark-matrix.sh` |

Just want to *run* the proven configs, not reproduce them? That's the registry —
[`README.md`](README.md#run-the-proven-configs-the-fast-path), five minutes.

---

## Path A — sparkrun, the board's own harness

### Install (no wizard needed)

```bash
# pin lives in config/serving-images.env (SPARKRUN_VERSION); no version literal here (CI-enforced, #93)
scripts/install-sparkrun.sh          # from the repo root
sparkrun update              # fetches the recipe registries (official/community/eugr/...)
# THIS repo is also a registry — the receipt-backed configs, runnable by name (recipes/README.md):
#   sparkrun registry add https://github.com/maxspevack/spark-rocky
#   sparkrun run @spark-rocky/<recipe> ...
```

The `sparkrun setup` wizard (cluster/SSH-mesh/sudoers/earlyoom) is **not required** for single-node
use; its two apt-coupled helpers (`setup earlyoom`, `setup system-update`) are the only
Ubuntu-assuming corners found — skip them here.

### Run the official board profile, single node

```bash
sparkrun benchmark <recipe> --hosts localhost --rootful \
  --profile @official/spark-arena-v2 --output results.yaml
```

- `@official/spark-arena-v2` is the leaderboard's run-rule surface: depths
  {0, 4k, 8k, 16k, 32k, 64k, 100k} × pp2048 × tg128 × concurrency {1, 2, 5, 10}, prefix caching on,
  runs=3, heat-aware cell order. `arena benchmark` (the submission path) hard-codes this profile, so
  cells map 1:1 to leaderboard columns (`tg128 @ d<depth> (c<N>)`) — board-comparable by construction.
- **`--hosts localhost` is required** (wizard-free hosts have no default hosts; without it:
  `No hosts specified`).
- **`--rootful` stays, by choice.** The rootless GPU path needs CDI specs on wizard-free hosts
  (`unresolvable CDI devices`); `--rootful` sidesteps it and is what every receipt on this host ran
  with ([sparkrun#225](https://github.com/spark-arena/sparkrun/issues/225) history).
- **If the recipe sets its served name inline** (in the `command:` string rather than a
  `served_model_name:` defaults key), llama-benchy gets the HF path, 404s on warmup, and the run
  dies at task 1 with an empty table. Override per-run: `-b served_model_name=<name>`. Not
  host-specific.

### 35B-class models: use the two-step (the one-shot's readiness wait is too short)

`sparkrun benchmark`'s server-readiness wait (~5 min) is shorter than a 35B's legitimate startup on
this box (~7 min: weight load + FlashInfer autotune) — the one-shot gives up and tears down a healthy
loading serve. Two-step instead:

```bash
sparkrun run <recipe> --hosts localhost --rootful --image <pinned tag> --no-follow
until curl -sf http://localhost:8000/v1/models >/dev/null; do sleep 5; done    # cap it yourself (~18 min)
rm -rf ~/.cache/sparkrun/benchmarks    # resume-state — see the traps below
sparkrun benchmark <recipe> --hosts localhost --rootful --image <pinned tag> \
  --profile @official/spark-arena-v2 --skip-run --output results.yaml
docker rm -f $(docker ps -aq --filter name=sparkrun)    # teardown — see the traps below
```

`--skip-run` also separates serve problems from measurement problems when diagnosing either.

### Three sparkrun traps this flow routes around

Hit live on 0.2.40 (2026-07-25, record on #74); status re-verified on the 0.3.x line (2026-07-27):

1. **Resume-state poisons repeat measurements.** `~/.cache/sparkrun/benchmarks/<id>/` keys on
   (model, profile), NOT recipe content — a repeat run of the same model+profile **returns the prior
   run's numbers wholesale**, no traffic ever reaching the server. `--fresh` clears state on the
   0.3.x line, but the key still excludes recipe content by design. Rule: clear the state dir before
   every measured run (the two-step above does). Detection: results identical at full float
   precision + zero request activity in the serve log.
2. **Teardown leaks.** `sparkrun stop --all --hosts localhost` exits 0 while containers keep running
   (ssh-to-self fails on wizard-free hosts; persists on 0.3.x —
   [#229](https://github.com/spark-arena/sparkrun/issues/229) /
   [PR #231](https://github.com/spark-arena/sparkrun/pull/231)). `docker rm -f` the `sparkrun*`
   containers between runs; verify `docker ps -aq | wc -l` → 0.
3. **The serve log lives inside the container.** With `run --no-follow`, vLLM output goes to
   `/tmp/sparkrun_serve.log` in-container (`docker logs` shows only the banner). `docker cp` it out
   **before** teardown — it is the only place MTP engagement (`SpecDecoding metrics`) and
   engine-init root causes can be read.

### Sustained sweeps: the chunked receipt protocol

A ~55-minute continuous v2 sweep thermally saturates a desk Spark ([`scoreboard.md`](scoreboard.md)
ch. 3) and gets discarded THROTTLED. `scripts/receipt-chunked.sh` — the runner behind both frontier
receipts — encodes the fix: the same 28 official cells in **segments**, a **cool-to-≤55°C gap**
between segments, per-segment thermal trace + `check-throttle.sh` verdict (any THROTTLED segment
re-runs from a cooled start), resume-state cleared per segment, headline cells N≥5 on a fresh serve.
First validated in full 2026-07-25: 11/11 segments CLEAN on cells two sustained attempts had failed.
Read the script's header for invocation.

---

## Path B — receipt-grade, the pipeline behind the parity claim

### The data model (how spark-arena stores entries)

spark-arena.com is a client-rendered app backed by **public Firebase/Firestore** (project
`spark-arena`). The leaderboard loads a pre-aggregated document keyed by **submission IDs**
(`sub<epoch_ms>`) — what `data/spark-arena-snapshot-*.json` captured. Detail pages use a **recipe
permalink UUID**; the two are linked inside each benchmark document:

```
snapshot entry .benchmarkId  ==  Firestore  benchmarks/<sub-ID>  (doc key)
                                              └── field recipePermalinkId = <UUID>
                                                   └── https://spark-arena.com/api/recipes/<UUID>/raw
```

The `benchmarks/<sub-ID>` document also carries the recipe inline and the published results
(`tokensPerSec`, `tests`, `tokensPerSecStdDev`). The `benchmarks` collection is world-readable;
`submissions`/`recipes`/`leaderboard` are not (403) — never needed.

### Step 1 — map an entry to its recipe

```bash
KEY="AIzaSyDy4gDrfBr0LnXdN7N2CT7IUq7oIQCBrpI"   # the site's own public web key, from its JS bundle
SUB="sub1772533296511"                            # = snapshot entry .benchmarkId for the target
curl -s "https://firestore.googleapis.com/v1/projects/spark-arena/databases/(default)/documents/benchmarks/$SUB?key=$KEY" \
  | grep -A1 recipePermalinkId
# -> stringValue: 28879af7-99f6-49bf-ae89-d6ceeb7eb229
```

(`data/fetch.sh <sub-id>` does steps 1–2 in one shot.)

### Step 2 — pull the exact recipe

```bash
UUID="28879af7-99f6-49bf-ae89-d6ceeb7eb229"
curl -fsSL -o recipes/<name>.yaml "https://spark-arena.com/api/recipes/$UUID/raw"
```

This yaml is the authoritative reproducer — the exact `vllm serve` command, defaults, env, mods, and
`container:` tag the entry was produced with. Commit it under `recipes/` (top level — verbatim
mirrors are never served by the registry tiers) and add its row to `recipes/MIRRORS.tsv`; CI enforces
the root-integrity ledger.

### Step 3 — serve it (spark-vllm-docker), single host

```bash
cd /root/spark-vllm-docker
# Serving image, two generations (config/serving-images.env, #71):
#   gen 1 (behind the June receipts): local builds — ./build-and-copy.sh [--tf5] -> vllm-node[-tf5]
#   gen 2 (current, preferred): pull the PINNED permanent mirror tag instead of building —
#     docker pull ghcr.io/spark-arena/dgx-vllm-eugr-nightly@$SERVING_IMAGE_DIGEST
#     and run a recipe VARIANT whose container: names that tag (recipes/*-<TAG>.yaml; variants
#     promote into recipes/spark-rocky/ once sparkrun-v2-expressed AND re-receipted — recipes/README.md).
./run-recipe.sh <name> --solo -d     # applies serve flags + mods + env from the recipe; host networking
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/health)" = 200 ]; do sleep 5; done
```

### Step 4 — measure

The leaderboard test `tg128 (c1)` = token-generation 128, concurrency 1. Single cell, N≥5:

```bash
uvx llama-benchy --base-url http://localhost:8000/v1 --model <HF/path> \
  --pp 2048 --tg 128 --concurrency 1 --runs 5
```

For the **full matrix** — the ~104-cell sweep the parity claim rests on — do not retype the params;
the canonical script carries the `llama-benchy` version pin and encodes the exact sweep, so every
reproduction measures the same surface:

```bash
scripts/run-benchmark-matrix.sh 8000 <HF/path> result.csv
```

### Step 5 — compare + record

Commit a receipt in `receipts/` (format: see `reproduce-Qwen3.5-0.8B-gen2-2026-07-24.txt`): host
stack, benchmark stack versions, the exact recipe, the exact commands, raw N≥5 output, the published
number, and every confound. The standing confound on every cross-date comparison: **spark-arena pins
no vLLM version**, so a date gap between images is a real runtime difference. Our side is closed
(#71): the pinned gen-2 mirror tag makes our runtime byte-identical for any third party; what remains
is the entry's side — state it.

---

## Traps that bite both paths

| Symptom | Cause | Do |
|---|---|---|
| Serve OOMs or "No available memory for the cache blocks" after prior runs | the open driver leaks GPU memory on container stop/crash | reboot to a clean pool before each serve series; `free -g` should read ~3 GiB used / ~118 GiB available |
| vLLM startup check fails while `free -g` shows plenty | unified memory: `cudaMemGetInfo` sees `MemFree`, and page cache from a big `docker pull` starves it | `sync && echo 3 > /proc/sys/vm/drop_caches` before serving (the serve-gate does this itself) |
| Two serves deadlock | nvidia-container-toolkit serializes GPU init | never start a second `docker run --gpus` while one is initializing |
| Numbers moved between dated runs | the container floated | pin it: **upstream** registry recipes name `:latest` (`@spark-rocky` recipes pin dated tags), and Docker's `missing` pull policy means a **local** tag wins — `docker tag ghcr.io/spark-arena/dgx-vllm-eugr-nightly:<SERVING_IMAGE_TAG> ghcr.io/spark-arena/dgx-vllm-eugr-nightly:latest` (same for `-tf5`, upstream's deprecated identical alias). Record the tag served |
| "Do I need a HuggingFace token?" | only for gated models | none of the official-tier registry targets are gated; **gemma-3-1b-it is** (license + token — its June receipt served with `HF_TOKEN` passed to the container). The model's HF page states its gating |
| The cache-blocks error on a correct recipe | `gpu-memory-utilization` is the **total** unified-memory budget (fraction × 121 GB = model + KV) | the recipe's value is authoritative — don't hand-tune it |
| A long matrix looks hung | `llama-benchy --save-result` writes the CSV only at the end; `nohup` block-buffers stdout | judge progress from the container's request log / `nvidia-smi` |

## Submission (reference — deliberately not exercised)

`sparkrun arena login` (admin-approved account) → `sparkrun arena benchmark <recipe>` → uploads
recipe + logs + metadata. Mechanism confirmed from source (#7); whether/when to create an account is
a maintainer decision. `arena benchmark --local-test` simulates the upload.
