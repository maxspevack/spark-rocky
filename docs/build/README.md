# Build it — how spark-rocky is made, and how to rebuild it

How deliverable #1 was built and how to reproduce it from source. This is the OS-development layer: a stock upstream kernel plus the open driver, with a config-only delta over upstream and zero carried patches.

- [`build.md`](build.md) — the `01`→`04` pipeline and prerequisites. **Start here.**
- [`platform-deltas.md`](platform-deltas.md) — every boot delta vs stock, classified (carry / upstream / decline / benign). The changeset ledger.
- [`dmesg-baseline.md`](dmesg-baseline.md) — the GB10 boot `err/crit` census, root-caused and benign; the stay-current dmesg gate diffs against it.
- [`software-stack.md`](software-stack.md) — the layer-by-layer stack and the delta vs DGX OS.
- [`third-party.md`](third-party.md) — adopted upstreams, version pins, and the zero-patch accounting.
- [`release.md`](release.md) — the maintainer release runbook: package, sign, tag, verify.
- [`downstream.md`](downstream.md) — building **on** spark-rocky as a downstream: the signed-release consumption contract (pin + verify + extend) + the `01`→`07` divergence seams (kernel / packages / validation). The M6 enablement.
- [`debug-hatch.md`](debug-hatch.md) — the locked-image debug-access model.
