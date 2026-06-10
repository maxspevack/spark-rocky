# config/ — kernel configs + the stock-DGX baseline

The evidence behind "zero patches" and the before/after of the host swap.

| File | What it is |
|---|---|
| `rocky-6.18.34-gb10.config` | **The kernel `.config` we build** — upstream 6.18.34 with GB10 enablement. This is the *only* kernel input we author, and it is configuration, not a source patch. Hash recorded in receipts. |
| `dgx-6.17-nvidia.config` | The **stock DGX OS** kernel config (`6.17.0-nvidia`, vendored), captured for comparison — what we swapped *from*. |
| `dgx-reference.txt` | Stock DGX OS capture (2026-06-08): kernel `6.17.0-1021-nvidia`, open driver `580.159.03`, `nvidia-smi`, ATS addressing mode. The baseline the swap is measured against. |
| `dgx-lsmod.txt` | Stock DGX OS loaded-module list — reference for what the vendored kernel ships. |

Used by [`../docs/stack-and-delta.md`](../docs/stack-and-delta.md) (the layer-by-layer swap) and the build
pipeline in [`../scripts/`](../scripts/) (step 1 feeds `rocky-6.18.34-gb10.config` to the kernel build).
