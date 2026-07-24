# config/ — the pins, the kernel config, and the stock-DGX baseline

The evidence behind "zero patches", every pin the build and benchmark stacks consume, and the
before/after of the host swap.

| File | What it is |
|---|---|
| `versions.env` | **The build pins** — `CLK_COMMIT` (the shipped kernel), `KVER`/`KERNEL_SHA256` (the stock A/B knob), `DRIVER_VER`/`DRIVER_SHA256`, `CUDA_VER`, `PAGE_SIZE`, `ROCKY_RELEASEVER`. The drift sensor (#24) watches these. Per the prose-pin rule ([`../THIRD_PARTY.md`](../THIRD_PARTY.md)), volatile coordinates live here, never in docs. |
| `serving-images.env` | **The serving/benchmark-stack pins** (#28/#71): generation 1 = the June local-build digests behind the parity receipts; generation 2 = the permanent dated `dgx-vllm` mirror tag + digest (current); plus `SPARKRUN_VERSION` (#72). The sensor's `SERVING` row watches the gen-2 tag's age. |
| `release.env` | **The consumption endpoint** — where `flash.sh` downloads the signed release from, and the pinned signing-key fingerprint it verifies against. |
| `rocky-6.18.34-gb10.config` | **The base kernel `.config` for the stock-kernel.org path** — upstream 6.18 with GB10 enablement. The filename pins the release it was first captured from (6.18.34); it **carries forward** to newer `$KVER` via `olddefconfig`. The *only* kernel input we author — configuration, not a source patch. (The CLK default builds with CLK's own aarch64 config.) Hash recorded in receipts. |
| `dgx-reference.txt` | Stock DGX OS capture (2026-06-08): kernel `6.17.0-1021-nvidia`, open driver `580.159.03`, `nvidia-smi`, ATS addressing mode. The baseline the swap is measured against. |
| `dgx-lsmod.txt` | Stock DGX OS loaded-module list — reference for what the vendored kernel ships. |
| `debug-authorized_keys` | The maintainer public key the baked debug hatch enables — see the debug-hatch section of [`docs/build/build.md`](../docs/build/build.md). Public key only; nothing secret lives in this repo. |

Used by [`docs/build/software-stack.md`](../docs/build/software-stack.md) (the layer-by-layer swap vs DGX OS) and the
build pipeline in [`../scripts/`](../scripts/) (step 1 feeds this `.config` to the kernel build; the base
config carries forward across point releases — `config/versions.env` pins which kernel).
