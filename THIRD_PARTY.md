# THIRD_PARTY.md — the supply-chain map + fork roster

Every third-party input this project consumes, in one table per class, with **where its pin
lives**. The prime rule, learned the hard way (two stale inline pins in one week):

> **Prose never carries a pin.** Every volatile coordinate (commit, digest, version, tag) lives
> in a machine-readable env file — [`config/versions.env`](config/versions.env) for the build,
> [`config/serving-images.env`](config/serving-images.env) for the serving/benchmark stack.
> This file maps *what* each input is, *why*, and *where its pin lives* — never the pin value.

Forking policy per the workspace Default-Fork doctrine (`~/dev/SHARED.md` → *Default-Fork OSS
Adoption*): tools adopted as primitives are forked to `maxspevack/*` before consumption. The
forks are **pure mirrors** (zero divergence — verified in the protocol below); they exist for
issue-filing, PR branches, and pin insurance, not for carrying patches. This project carries
**zero patches against anything**.

## Build inputs (pins: `config/versions.env`)

| Input | Upstream | Forked? | Pin variable(s) | Integrity model |
|---|---|---|---|---|
| CIQ Linux Kernel (CLK) | [`ctrliq/kernel-src-tree`](https://github.com/ctrliq/kernel-src-tree) `ciq-6.18.y` | **No — deliberate.** A CIQ-org tree; commit-pinned consumption, and the drift sensor (#24) watches the branch tip. A fork would add nothing: we file issues/PRs as CIQ. | `CLK_COMMIT` | commit-addressed over TLS (GitHub archives are not byte-stable; no tarball hash exists to pin) |
| stock kernel (A/B knob) | kernel.org | No — infrastructure, not a primitive | `KVER`, `KERNEL_SHA256` | GPG-signed `sha256sums.asc`; empty pin is FATAL in `01` |
| NVIDIA open GPU modules + driver `.run` | [`NVIDIA/open-gpu-kernel-modules`](https://github.com/NVIDIA/open-gpu-kernel-modules) / NVIDIA download | No — vendor releases, consumed as published; the drift sensor watches releases | `DRIVER_VER`, `DRIVER_SHA256` | TOFU at bump (TLS + the `.run` embedded `--check`); `02b`/`02c`/`upgrade-metal` verify fail-closed |
| Rocky Linux userspace + firmware rpms | Rocky 10 BaseOS/AppStream | No — distro packages | `ROCKY_RELEASEVER` (packages float; firmware = `mt7xxx-firmware` + `wireless-regdb`) | dnf `gpgcheck=1` everywhere; `05` gates unverified repos |
| CUDA toolkit (host, minimal) | NVIDIA el10 repo | No — distro-style repo | `CUDA_VER` | dnf `gpgcheck=1` + imported repo key |

## The Spark benchmarking stack (pins: `config/serving-images.env`)

All six are forked to `maxspevack/<name>`; local clones (where present) live **flat under
`~/dev/<name>`** with `origin` = the fork, `upstream` = the source.

| Upstream | Role | Consumed as | Pin lives at |
|---|---|---|---|
| [`eugr/spark-vllm-docker`](https://github.com/eugr/spark-vllm-docker) | serving-container build system behind the June parity receipts; `run-recipe.sh` drives the serve-gate | cloned on the box (`/root/spark-vllm-docker`), pinned checkout | `serving-images.env` (`SPARK_VLLM_DOCKER_COMMIT` for the June generation; `SERVING_SVD_COMMIT` for the gen-2 image's provenance) |
| [`eugr/llama-benchy`](https://github.com/eugr/llama-benchy) | the benchmark meter (spark-arena's canonical tool) | `uvx` from PyPI | `scripts/run-benchmark-matrix.sh` (`llama-benchy==<ver>` — the one permitted non-env pin: it must ride the command line, and the matrix script is itself the canonical-measurement artifact) |
| [`spark-arena/sparkrun`](https://github.com/spark-arena/sparkrun) | official runner + `arena benchmark` submission CLI; validated on this host (#72, [`docs/benchmark/sparkrun-harness.md`](docs/benchmark/sparkrun-harness.md)) | `uv tool install` on the box | `serving-images.env` (`SPARKRUN_VERSION`, `SPARKRUN_LLAMA_BENCHY`) |
| [`spark-arena/recipe-registry`](https://github.com/spark-arena/recipe-registry) | official recipes + the v1/v2 benchmark profiles (the board's run rules) | reference at HEAD | the per-receipt recipe copy in `receipts/` is the pin |
| [`spark-arena/community-recipe-registry`](https://github.com/spark-arena/community-recipe-registry) | **our upstream contribution path** — recipes PR into `recipes/<model>/maxspevack/` (#75) | PR target | n/a — contribution target, not a dependency |
| [`spark-arena/dgx-vllm`](https://github.com/spark-arena/dgx-vllm) | **the serving-image pin source since 2026-07-24** (#71 generation-2): permanent dated mirror tags of eugr's vLLM nightlies; `build-index.json` maps tag → vLLM/FlashInfer coordinates | images pulled from ghcr by tag | `serving-images.env` (`SERVING_IMAGE_TAG` + digests); the June-generation digests stay as the receipt-era baseline. The drift sensor's `SERVING` row watches the tag age (INFO < 31 days, DRIFT past) |

## Layout decision (2026-07-24): flat, not an org directory

The clones do **not** nest under `~/dev/spark-arena/`, deliberately: the working set spans two
GitHub orgs (`spark-arena/*` + the two most load-bearing pieces from `eugr/*`), so an org-named
directory would split the actual unit — "the Spark benchmarking stack" — across two locations
to mirror an upstream boundary that means nothing to consumption. The grouping lives HERE, in
the consumer's registry; the filesystem stays flat per the workspace doctrine (`~/dev/.gitignore`
lists each clone). **Revisit if** the family grows past ~8 clones or a second consumer project
appears — then a grouping directory earns its tooling cost.

## Maintenance protocol (AI-executable — run at every release cut + the monthly `/repo-sync` pass)

Each check is a command with an expected answer; a mismatch is a finding to fix in the same
change that moves the pin. The release runbook ([`docs/build/release.md`](docs/build/release.md))
carries this as a cut step.

1. **Fork mirrors are pure and current** (all six; `fork-ahead` MUST be 0 — divergence means a
   patch snuck in; `fork-behind` > 0 → `gh repo sync maxspevack/<name>`; `dgx-vllm` behind-by-1
   is its daily-mirror steady state):
   ```
   for p in eugr/spark-vllm-docker eugr/llama-benchy spark-arena/sparkrun \
            spark-arena/recipe-registry spark-arena/community-recipe-registry spark-arena/dgx-vllm; do
     gh api "repos/$p/compare/main...maxspevack:${p#*/}:main" \
       --jq "\"${p#*/}: behind=\" + (.behind_by|tostring) + \" AHEAD=\" + (.ahead_by|tostring)"
   done
   ```
2. **Local clone remotes are fork+upstream** (for every `~/dev/<name>` that exists):
   `git -C ~/dev/<name> remote -v` → `origin` = `maxspevack/`, `upstream` = the source org.
3. **This file carries no pin values**: `grep -E '[0-9a-f]{12,40}|sha256[:]' THIRD_PARTY.md`
   returns nothing (the test suite enforces this — a hit means a pin leaked into prose; the
   bracketed colon keeps this very line from matching itself).
4. **The pin files agree with the box**: the box's `/root/spark-vllm-docker` checkout is at
   `SPARK_VLLM_DOCKER_COMMIT`; the serve-gate recipe runs the image `serving-images.env` names.
5. **Row currency**: any issue this file cites as pending (`#71`, `#72`, `#75`) that has closed
   means its row is stale — update the row in the same pass.

## Deliberately not tracked

`spark-arena/blog` (content, dormant since 2026-04) and `spark-arena/spark-arena-cli` (the
deprecated pre-sparkrun submission path). The board itself records no OS/kernel/driver field —
the substrate story travels in recipes and receipts (#75), never in the board UI.
