# config/ — kernel configs + the stock-DGX baseline

The evidence behind "zero patches" and the before/after of the host swap.

| File | What it is |
|---|---|
| `rocky-6.18.34-gb10.config` | **The base kernel `.config` we build** — upstream 6.18 with GB10 enablement. The filename pins the release it was first captured from (6.18.34); it **carries forward** to newer `$KVER` via `olddefconfig` (see `versions.env`). The *only* kernel input we author — configuration, not a source patch. Hash recorded in receipts. |
| `dgx-reference.txt` | Stock DGX OS capture (2026-06-08): kernel `6.17.0-1021-nvidia`, open driver `580.159.03`, `nvidia-smi`, ATS addressing mode. The baseline the swap is measured against. |
| `dgx-lsmod.txt` | Stock DGX OS loaded-module list — reference for what the vendored kernel ships. |

Used by [`docs/build/software-stack.md`](../docs/build/software-stack.md) (the layer-by-layer swap vs DGX OS) and the
build pipeline in [`../scripts/`](../scripts/) (step 1 feeds this `.config` to the kernel build; the base
config carries forward across point releases — `config/versions.env` pins which kernel).
