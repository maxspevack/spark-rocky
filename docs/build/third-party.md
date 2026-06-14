# THIRD_PARTY.md — adopted upstreams (adopt-by-fork doctrine)

Tracks every third-party tool the benchmark stack depends on: upstream, the version actually in use, our
fork, carried patches, and the upstream-filing plan.

**Rule:** stay close to upstream; carry the fewest patches possible; file every delta upstream.

## What we actually run (verified 2026-06-10, on the box)

| Tool | Role | Upstream | Version in use | Our fork | Carried patches |
|---|---|---|---|---|---|
| spark-vllm-docker | builds the vLLM serving image; `run-recipe.sh` applies a spark-arena recipe | `eugr/spark-vllm-docker` | upstream `8b6347d` (2026-06-07) | `maxspevack/spark-vllm-docker` | **none** |
| llama-benchy | the canonical benchmark client (spark-vllm-docker README §9 names it) | `eugr/llama-benchy` | **pinned `0.3.8`** — `uvx 'llama-benchy==0.3.8'` | `maxspevack/llama-benchy` | **none** |
| sparkrun | Spark Arena's official end-to-end runner (`setup`/`run`/`show`/`logs`/`status`/`stop`) | `spark-arena/sparkrun` | not used yet | `maxspevack/sparkrun` | **none** |

**Carried patches across the entire stack: NONE.** No `.patch`/`.diff` in this repo; no build script invokes
`patch`/`git apply`; the box's spark-vllm-docker checkout has zero local modifications. This matches the host
layer (kernel + driver carry no patches; see the build scripts and `config/rocky-6.18.34-gb10.config`).

**Host/platform side (this table defers to two places, to avoid duplicating the accounting):** the kernel
`.config` + the DGX baseline live in [`config/`](../../config/); the boot-time platform deltas — each classified
*carry / upstream / decline / benign* — plus the firmware-currency conclusion live in
[`platform-deltas.md`](platform-deltas.md). Platform firmware is NVIDIA's, applied **unmodified** via
stock public `fwupd`/LVFS (the box is on the latest published) — adopted, not carried or patched.

## Fork vs. upstream — why the box runs upstream

We forked all three per the adopt-by-fork doctrine, but **because we carry zero patches, the box runs
upstream directly.** A fork earns its keep only when we need to (a) carry a local patch or (b) pin a
divergent build — neither is true yet. So we deliberately do **not** keep the forks rebased to tip; they are
standing landing-zones for the first patch we ever need. When that day comes: branch the fork, apply the
patch, point the box at the fork, record it in the table above, and open the upstream PR. Until then, "the
fork is N commits behind upstream" is not a problem to fix — it is the expected state of an unused safety net.

## Versioning / reproducibility

`uvx llama-benchy` **bare** resolves to whatever is latest on PyPI at run time — convenient, but not
reproducible. So every receipt and the pipeline **pin the version**: `uvx 'llama-benchy==0.3.8'`. The serving
side is pinned by the image's recorded vLLM build (in each receipt). The one thing the *leaderboard* does not
pin is vLLM (the image compiles latest at build time), so cross-date comparisons carry a runtime-version
drift — named on every receipt.

## Recipes are not ours

Serve configs are pulled **verbatim** from spark-arena's per-entry recipe API (`/api/recipes/<permalink>/raw`)
and committed under `recipes/`. The entry→recipe mapping (Firestore `benchmarks/<sub-ID>` →
`recipePermalinkId`) is documented in [`../benchmark/reproduce-pipeline.md`](../benchmark/reproduce-pipeline.md).

## Submitting results to spark-arena (the sparkrun question)

`sparkrun`'s documented surface is `setup`/`run`/`show`/`logs`/`status`/`stop` — it **runs** any recipe from
the registries (official, community, and the benchmarked recipes browsable on spark-arena.com). It is **not**
limited to Atlas/SGLang (an earlier note here said so — wrong). Its README documents running and browsing,
**not** a `submit`/`upload` command, so the path for posting a result to the leaderboard is most likely the
**spark-arena.com site itself**. sparkrun is not needed for *reproduction* — `spark-vllm-docker` +
`llama-benchy` + the recipe API cover that — so it stays unpulled until we submit, or until an Atlas/SGLang
target requires it.

## Upstream-filing plan

- `eugr/spark-vllm-docker`, `eugr/llama-benchy`: file issues/PRs upstream for any GB10/sm_121 fix we make.
- Submitting reproduced results: Max submits after peer review (mechanism per the section above).
