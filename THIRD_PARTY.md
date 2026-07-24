# THIRD_PARTY.md — fork roster + authoritative pins

Every third-party primitive this project consumes is forked to `maxspevack/*` before
consumption, per the workspace Default-Fork doctrine (`~/dev/SHARED.md` → *Default-Fork
OSS Adoption*). The workspace-level roster (`~/dev/THIRD_PARTY.md`) points here — **this
file is the authoritative pin registry** for the Spark benchmarking stack. The box runs
every one of these **upstream, zero patches**; the forks exist for issue-filing, PR
branches, and pin insurance, not divergence.

Local clones (where present) live flat under `~/dev/<name>` with `origin` = the fork and
`upstream` = the source project. `/repo-sync` reports fork drift and mirrors via
`gh repo sync` (fast-forward only).

## Roster

| Upstream | Our fork | Role | Consumed as | Authoritative pin |
|---|---|---|---|---|
| [`eugr/spark-vllm-docker`](https://github.com/eugr/spark-vllm-docker) | `maxspevack/spark-vllm-docker` | serving-container build system behind the parity receipts | cloned on the box (`/root/spark-vllm-docker`) | commit `8b6347d` (2026-06-07) + **image digests in [`config/serving-images.env`](config/serving-images.env)** — the digests are the real pin |
| [`eugr/llama-benchy`](https://github.com/eugr/llama-benchy) | `maxspevack/llama-benchy` | the benchmark meter (spark-arena's canonical tool) | `uvx` from PyPI | `llama-benchy==0.3.8`, pinned in [`scripts/run-benchmark-matrix.sh`](scripts/run-benchmark-matrix.sh) |
| [`spark-arena/sparkrun`](https://github.com/spark-arena/sparkrun) | `maxspevack/sparkrun` | official runner + `arena benchmark` submission CLI + the board's harness | adoption in **#72** (not yet consumed on the box) | none yet — upstream 0.2.40 at adoption time; pin lands with #72 validation |
| [`spark-arena/recipe-registry`](https://github.com/spark-arena/recipe-registry) | `maxspevack/recipe-registry` | official recipes + the **v1/v2 benchmark profiles (the board's run rules)** | reference; every receipt records the full recipe it ran | consumed at HEAD — the per-receipt recipe copy is the pin |
| [`spark-arena/community-recipe-registry`](https://github.com/spark-arena/community-recipe-registry) | `maxspevack/community-recipe-registry` | **our upstream contribution path** — recipes PR into `recipes/<model>/maxspevack/` | PR target (**#75**) | n/a — contribution target, not a dependency |
| [`spark-arena/dgx-vllm`](https://github.com/spark-arena/dgx-vllm) | `maxspevack/dgx-vllm` | permanent dated mirror tags of eugr's vLLM nightlies; `build-index.json` maps tag → vLLM/FlashInfer commits | serving-image pin source going forward (**#71**) | migration tracked in #71; until it lands, [`config/serving-images.env`](config/serving-images.env) digests remain authoritative |

## Sync cadence

Per the doctrine: the **pin is the control point; the fork branch is a mirror.**

- **Mirror:** `gh repo sync maxspevack/<repo>` on the monthly `/repo-sync` pass (fast-forward
  only — refusal on divergence is the signal to stop and look).
- **Pin moves are deliberate:** read the upstream delta, test on the box, update the pin and
  this file in the same change. Event trigger dominates calendar: refresh a dep's pin before
  building anything new on top of it.
- **Drift sensing:** #24's drift-check covers the kernel; #71 extends it to the dgx-vllm
  mirror tags. Registries and sparkrun are release-cadence slow — the monthly pass suffices.

## Notes

- spark-arena's board records no OS/kernel/driver field; the substrate story travels in
  recipes and receipts (#75), never in the board UI.
- `spark-arena/blog` and `spark-arena/spark-arena-cli` are deliberately **not** tracked:
  the blog is content (2 posts, dormant since 2026-04), and the CLI is the deprecated
  pre-sparkrun submission path.
