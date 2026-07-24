# spark-rocky — single entry point for the 01->04 build pipeline.
# Run ON the DGX Spark (aarch64 + Docker). Versions are pinned in config/versions.env
# (bump there to stay current). Stages are also runnable individually.
#
#   make all        full build: kernel -> rootfs -> gpu -> driver -> image (+ flash to USB)
#   make image      (re)assemble the bootable image + flash to USB (step 04 only)
#   make kernel | rootfs | gpu | driver | open-module     run one stage
#   make proof      proof-of-life (OS + kernel + nvidia-smi + a CUDA vectorAdd)
#   make install    install the booted USB onto the NVMe (DESTRUCTIVE; run from the USB)
#   make test       repo test suite (script syntax + behavioral invariants; no GB10 needed)
#   make versions   show the pinned versions
include config/versions.env
export
# Invoke via `bash` so the entry point works regardless of the scripts' executable bit
# (a GitHub zip download or a stray scp strips +x; git clone preserves it).
R := bash scripts

.PHONY: help all kernel rootfs gpu driver open-module image proof install test versions

help: ; @echo "make [all|kernel|rootfs|gpu|driver|open-module|image|proof|install|test|versions]  (versions pinned in config/versions.env)"

all: ; $(R)/01-build-kernel.sh && $(R)/02-build-rootfs.sh && $(R)/02b-install-gpu-docker.sh && $(R)/02c-driver-userspace.sh && $(R)/04-build-image.sh

kernel:      ; $(R)/01-build-kernel.sh
rootfs:      ; $(R)/02-build-rootfs.sh
gpu:         ; $(R)/02b-install-gpu-docker.sh
driver:      ; $(R)/02c-driver-userspace.sh
open-module: ; $(R)/03-build-nvidia-open.sh
image:       ; $(R)/04-build-image.sh
proof:       ; $(R)/proof-of-life.sh
install:     ; $(R)/install-baremetal.sh
test:        ; bash tests/run-tests.sh
versions:    ; @printf 'KERNEL_SOURCE=%s  CLK_COMMIT=%.12s  KVER=%s (kernelorg A/B pin)  DRIVER_VER=%s  ROCKY_RELEASEVER=%s  PAGE_SIZE=%s\n' '$(strip $(KERNEL_SOURCE))' '$(strip $(CLK_COMMIT))' '$(strip $(KVER))' '$(strip $(DRIVER_VER))' '$(strip $(ROCKY_RELEASEVER))' '$(strip $(PAGE_SIZE))'
