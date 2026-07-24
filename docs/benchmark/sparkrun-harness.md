# sparkrun on this host — the board's own harness, validated

[sparkrun](https://github.com/spark-arena/sparkrun) is how spark-arena entries are actually
produced: registry recipes + the official benchmark profile + (for submitters) `arena benchmark`
upload. This page records the validated path for running it **on this stack** (Rocky 10.2 +
CLK kernel + open driver), alongside — not replacing — the receipt-grade
[`reproduce-pipeline.md`](reproduce-pipeline.md) flow. Validation evidence: #72.

## Install (no wizard needed)

```bash
uv tool install sparkrun     # Python >= 3.12; Rocky 10.2's 3.12 qualifies
sparkrun update              # fetches the recipe registries (official/community/eugr/...)
```

The `sparkrun setup` wizard (cluster/SSH-mesh/sudoers/earlyoom) is **not required** for
single-node use, and its two apt-coupled helpers (`setup earlyoom`, `setup system-update`) are
the only Ubuntu-assuming corners found — skip them here; earlyoom is `dnf install earlyoom`
if ever wanted.

## Run the official board profile, single node

```bash
sparkrun benchmark <recipe> --hosts localhost --rootful \
  --profile @official/spark-arena-v2 --output results.yaml
```

Two host-compat divergences were hit on this stack (everything else ran unmodified):

- **`--hosts localhost` is required.** Without the setup wizard there are no configured default
  hosts, and `sparkrun benchmark` errors out (`No hosts specified`) — the localhost fast path
  exists in the launcher but is not the CLI default.
- **`--rootful` is required until [sparkrun#225](https://github.com/spark-arena/sparkrun/issues/225)
  is fixed.** The default rootless path adds `--device /dev/infiniband` unconditionally; this
  stack blacklists `mlx5_core` (unused single-host NICs, see #46), so the node doesn't exist and
  the container dies in `Created` state — silently (`sparkrun run` detaches rc=0 regardless).
  Filed upstream with root cause + fix shape; drop `--rootful` when it lands.
- **If the recipe sets its served name inline** (in the `command:` string rather than as a
  `served_model_name:` defaults key), llama-benchy gets the HF path instead, 404s on warmup, and
  the run dies at task 1 with an empty table. Override per-run: `-b served_model_name=<name>`.
  Not host-specific — any sparkrun user benchmarking such a recipe hits it.

Also useful: cold `torch.compile` on a first serve here ran ~6.5 minutes — inside sparkrun's
15-minute port wait, but be patient before diagnosing; `--skip-run` benchmarks an
already-serving instance and separates serve problems from measurement problems.
- `@official/spark-arena-v2` is the leaderboard's run-rule surface: depths
  {0, 4k, 8k, 16k, 32k, 64k, 100k} × pp2048 × tg128 × concurrency {1, 2, 5, 10},
  prefix caching on, runs=3, heat-aware cell order. `arena benchmark` (the submission path)
  hard-codes this same profile.
- Cells map 1:1 to leaderboard columns (`tg128 @ d<depth> (c<N>)` etc.), so results are
  board-comparable by construction.

## Pinning the container (do not float on `latest`)

Registry recipes name `ghcr.io/spark-arena/dgx-vllm-eugr-nightly[-tf5]:latest`. Docker's
`missing` pull policy means a **local** tag by that name wins — so pin by locally tagging the
generation-2 image from [`config/serving-images.env`](../../config/serving-images.env) over the
`latest` name before benchmarking:

```bash
docker tag ghcr.io/spark-arena/dgx-vllm-eugr-nightly:<SERVING_IMAGE_TAG> \
           ghcr.io/spark-arena/dgx-vllm-eugr-nightly-tf5:latest
```

(`-tf5` is upstream's deprecated alias of `-nightly` — identical content by their own
deprecation note — so the local tag is semantically truthful.) Record the tag actually served
in any result you keep.

## Box hygiene (same sensors as the receipt flow)

- Reboot to a clean pool before a serve series (driver leaks GPU memory on container stop).
- `sync && echo 3 > /proc/sys/vm/drop_caches` before serving — on unified memory,
  `cudaMemGetInfo` sees `MemFree`, and page cache from a prior image pull starves vLLM's
  startup check (hit live 2026-07-24; the serve-gate now does this itself).
- Never two concurrent `docker run --gpus`.

## Submission (for reference — deliberately not exercised)

`sparkrun arena login` (account is admin-approved) → `sparkrun arena benchmark <recipe>` →
uploads recipe + logs + metadata to the board's storage. Mechanism confirmed from source (#7);
whether/when to create an account is a maintainer decision, not part of this validation.
`arena benchmark --local-test` exists for a simulated-upload smoke run.

## When to use which harness

| | `reproduce-pipeline.md` (spark-vllm-docker + matrix script) | sparkrun + v2 profile |
|---|---|---|
| Purpose | receipt-grade reproduction/regression (N≥5, templog, throttle detector) | board-comparable cells, the community's exact flow |
| Matrix | the canonical ~104-cell sweep | the official 28-cell × 3-run profile |
| Use for | parity claims, drift reads, receipts | pre-submission runs, cross-checking our numbers against board methodology |
