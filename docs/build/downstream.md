# Building downstream on spark-rocky

spark-rocky is built to be **consumed**, not forked. CIQ and others build distributions and appliances on top
with **zero carried patches**: **pin a signed release, verify it, and extend it through documented seams** —
never "fork + diverge". This doc is the contract (what you pin, how you verify) and the seams (where you
cleanly diverge).

The invariant that makes this safe: a release's **served bytes == the git tag they were built from**, enforced
by [`scripts/07-verify-release.sh`](../../scripts/07-verify-release.sh) (#35). `07` enforces **served == tag**;
HEAD advancing *past* the tag afterward is a **warning, not a failure** — so pin a tag, don't track `HEAD`.

---

## 1. The consumption contract

### What a release is

| Artifact | What it is | Where |
|---|---|---|
| tag `spark-rocky-live-<YYYYMMDD>` | the git commit the image was built from | the repo |
| `spark-rocky-live-aarch64-<kver>-<date>.raw.xz` | the bootable image (xz-compressed) | `gs://spark-rocky` |
| `…-<date>.BUILD-MANIFEST.txt` | provenance: `git_commit`, `artifact_sha256`, kernel release, page size, driver, CUDA, the resolved `.config` sha256 | `gs://spark-rocky` |
| `CHECKSUM` | one GPG-clearsigned file covering the artifacts (Fedora model — no unsigned duplicate to swap) | `gs://spark-rocky` |
| `spark-rocky-release-key.asc` | the release public key | the repo (`keys/`) + the bucket |

### What you pin, and how
**Pin the git tag as your source of truth** (e.g. as a submodule / manifest ref), and record the release's
`artifact_sha256` from the verified `BUILD-MANIFEST`. The model is **source-pin + rebuild**: pin the tag and
rebuild `01`→`04` from that pinned source, extending via the seams in §2 — not flashing the prebuilt image.
(`01`→`04` rebuilds the base; a downstream that bakes its own packages also runs `05`→`07` to package, sign, and verify *its own* release — see Seam 2.)
(`flash.sh` is the **end-user** path — download → fingerprint-verify → write a USB — and **nothing in the
downstream path runs it**.)

### How you verify
Run the maintainer's own check against the release you pin:
```
scripts/07-verify-release.sh spark-rocky-live-20260629
```
It fails closed unless **(a)** the served `BUILD-MANIFEST` `git_commit` == the tag's commit, **(b)** the served
`CHECKSUM` carries a **Good GPG signature from the release public key shipped in `keys/spark-rocky-release-key.asc`**,
and **(c)** the served image's `artifact_sha256` is the one inside that signed `CHECKSUM`.

**Establish the trust root yourself — this is the one thing the doc cannot do for you.** `07-verify` trusts the
key file in the repo; it checks the signature is *good*, not that it is a *specific* fingerprint. So before you
trust `07`'s green, confirm the release-key fingerprint —
**`71C1 6676 F9D4 0A4C E0C6 EB66 08B1 4BC3 9831 1101`** — **out-of-band** with the maintainer (don't trust an
in-repo copy in isolation). The fingerprint-*pinned* path is `flash.sh` (it asserts `VALIDSIG <fpr>`); a
downstream that wants fingerprint-pinned verification should pin that fingerprint itself, the way `flash.sh`
does, rather than rely on `07`'s "Good signature" grep. If the key rotates, the new fingerprint is published in
the repo (`keys/` + [`docs/use/verify.md`](../use/verify.md)) and must be re-confirmed out-of-band.

### Stability guarantees — and what is not promised
**Stable — build on these:**
- `served == tag` and the `07-verify` check that proves it.
- The `BUILD-MANIFEST` field set a downstream keys off: `git_commit`, **`artifact_sha256`**, `kernel`,
  `page size`, `driver`, CUDA, resolved `.config` sha256.
- The signed-`CHECKSUM` model and the release key (the **fingerprint is the trust root**; rotation published as
  above).
- The seams in §2 are the **intended** extension points; their shape is stable **in intent**.

**Not promised:** spark-rocky is **soft-launched and unsupported** — best-effort, provided as-is. **No currency
promise** (no committed cadence, no breakage SLA; #29). The seams are the intended interface, but **not under an
SLA** — the `01`→`07` shape can change between releases. A downstream that needs a frozen interface, a cadence,
or support **owns that itself**: pin a specific release and move deliberately; don't track `HEAD`.

---

## 2. The divergence seams

The `01`→`07` pipeline has three seams where a downstream diverges by **configuration and layering**, never by
editing an upstream script or carrying a `.patch`. `config/versions.env` is the single pinned source of truth;
every stage sources it.

### Seam 1 — Kernel (`versions.env`: `KERNEL_SOURCE` + `KVER` + `KCONFIG`)
`01-build-kernel.sh` dispatches on `KERNEL_SOURCE`. **`kernelorg` (a stock kernel.org tarball) is the live path
today;** `clk` (a CIQ CLK kernel) is **in progress — #52, not wired yet.** The base `.config` (`$KCONFIG`, e.g.
`config/rocky-6.18.34-gb10.config`) is a **deliberately-frozen base**: `olddefconfig` carries it forward to
`$KVER`, so its filename pins the *base lineage*, not the built kernel version (that's `KVER`). **To diverge:**
change `KVER` (and/or supply your own base `.config`) and reuse `01`→`07` unchanged; the `01` SIGNAL-READOUT
prints the GB10-symbol delta so you see exactly what your kernel choice keeps vs upstream. A different
`kernelorg` `KVER` runs today; a vendor/CLK kernel lands when its `KERNEL_SOURCE` is wired (#52).

### Seam 2 — Packages (`02` / `02b`) — and where the layer goes relative to the `05` gate
`02` lays down a current Rocky rootfs at `ROCKY_RELEASEVER`; `02b` adds the GPU stack (CUDA pin `CUDA_VER`,
container runtime, the open `.ko`). Two layering points, with **different verifiability consequences** — this is
the one a downstream trips on, so it's explicit:
- **Post-boot, on the booted box (the designed path):** `02` installs only minimal CUDA and notes the box pulls
  the full toolkit/stack post-install. This leaves the **shipped image bytes untouched**, so the base still
  **verifies against the spark-rocky release**.
- **Into the rootfs before `05` (`$W/rocky-img/rootfs`):** also clean — an additive `dnf --installroot` stage
  between `02b` and `04`, no fork of `02` — **but it produces a new image.** `05` computes a different
  `artifact_sha256` and `06` signs a different `CHECKSUM`, so the result verifies against **the downstream's own
  signed release** (same patch-free base, **not** byte-identical to spark-rocky's). `07-verify` of the
  *spark-rocky* tag will not describe it — expected; a downstream that bakes packages ships its own release.

### Seam 3 — Validation (`scripts/validate.sh`)
`validate.sh` is the upstream **doctor** — self-contained (provenance == image, open driver + `nvidia-smi` + a
real inlined CUDA kernel, runtime boot-hygiene). **To diverge:** extend it, or add a sibling suite, for the
components you layered on. There is no plugin hook — a downstream edits the file or ships its own suite, by
convention. Clean split: the upstream doctor answers *"is the spark-rocky base healthy?"*; the downstream owns
*"is my added layer healthy?"*.

---

## 3. Worked example — a CIQ-style downstream
A downstream wanting **a different kernel, added platform packages, and an added validation suite**:
1. **Kernel:** set `KVER` to a different stock `kernelorg` release today (or a vendor/CLK kernel once #52 wires
   `KERNEL_SOURCE`); rebuild `01`→`04`.
2. **Packages:** layer platform packages — **post-boot** to stay byte-verifiable against spark-rocky, or
   **pre-`05`** to bake them into the downstream's own signed release (Seam 2).
3. **Validation:** extend `validate.sh` for the layered components.

Every change is a config value or an additive layer; the upstream scripts are untouched; the downstream carries
**zero patches**.

---

## Are you still a consumer, or have you forked?
The one-way door is **carrying a patch**: the moment you edit an upstream script or carry a `.patch`, every
future re-pin becomes a rebase, not a config change — that's fork-and-diverge, and you've lost the cheap re-pin
that this whole contract exists to give you. Decidable self-check against your pinned tag:
```
git diff <pinned-tag> HEAD -- scripts/ config/    # empty  → you have not edited upstream
find . \( -name '*.patch' -o -name '*.diff' \)    # empty  → you carry no patches
```
Both empty → you are still a **consumer**; re-pinning a newer release is a config exercise. Either non-empty →
you have **forked**, and re-pinning is now a rebase. (Upstream itself holds both empty — there is no
`.patch`/`.diff` anywhere in this repo — and diverging through the seams above is what keeps a downstream
patch-free too. That is the whole point of M6: enable downstream innovation on a pinnable, verifiable,
patch-free upstream.)
