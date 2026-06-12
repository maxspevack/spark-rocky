#!/bin/bash
# Stage 1b: add the GPU stack + container runtime + open driver kernel module into the Rocky rootfs.
# - docker + nvidia-container-toolkit (the benchmark runs vLLM in a container)
# - the open driver: build .ko against our $KVER tree, install into the rootfs; add el10 driver userspace libs
# Parameterized via config/versions.env. Non-destructive: writes to $W/rocky-img + $W/driver-610.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, ROCKY_RELEASEVER
W="${W:-$(dirname "$HERE")}"
[ -d "$W/rocky-img/rootfs" ] || { echo "FATAL: rootfs missing — run 02-build-rootfs.sh first"; exit 1; }

docker run --rm -v "$W":/host -e KVER="$KVER" -e DRIVER_VER="$DRIVER_VER" -e RV="$ROCKY_RELEASEVER" rockylinux/rockylinux:10 bash -c '
set -euo pipefail
R=/host/rocky-img/rootfs
dnf install -y -q make gcc kmod findutils tar xz wget curl >/dev/null 2>&1

echo "[gpu] container runtime repos into rootfs"
cat >"$R/etc/yum.repos.d/docker.repo" <<EOF
[docker-ce]
name=docker-ce
baseurl=https://download.docker.com/linux/centos/10/aarch64/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
EOF
# nvidia-container-toolkit.repo ships from upstream with gpgcheck=1 + repo_gpgcheck=1 + a gpgkey.
# Leave them ON (Bruce: do NOT sed them off) so both the build-time install and the colleagues
# runtime dnf verify signatures. dnf -y auto-imports the gpgkey into the installroot.
curl -fsSL -o "$R/etc/yum.repos.d/nvidia-container-toolkit.repo" https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
dnf -y --installroot="$R" --releasever="$RV" --setopt=install_weak_deps=False install \
  docker-ce docker-ce-cli containerd.io nvidia-container-toolkit >/host/rocky-img/gpu.log 2>&1
echo "[gpu] docker+toolkit OK"

echo "[gpu] driver userspace libs (el10 $DRIVER_VER, belt-and-suspenders; 02c installs the real userspace via .run)"
dnf -y --installroot="$R" --releasever="$RV" --setopt=install_weak_deps=False install \
  nvidia-driver-cuda-libs nvidia-driver-libs >>/host/rocky-img/gpu.log 2>&1 || echo "[gpu] dnf driver-libs soft-skip (02c is the real userspace install)"

echo "[gpu] ensure driver .run downloaded + extracted at /host/driver-610 (shared with 02c/03)"
RUN=NVIDIA-Linux-aarch64-$DRIVER_VER.run
DRV=/host/driver-610/NVIDIA-Linux-aarch64-$DRIVER_VER
if [ ! -d "$DRV" ]; then
  mkdir -p /host/driver-610; cd /host/driver-610
  [ -f "$RUN" ] || curl -fsSL -m300 -o "$RUN" "https://us.download.nvidia.com/XFree86/aarch64/$DRIVER_VER/$RUN"
  sh "$RUN" -x >/dev/null 2>&1
fi

echo "[gpu] building + installing open .ko (against $KVER, el10 gcc-14) into rootfs"
cd "$DRV/kernel-open"
make clean >/dev/null 2>&1 || true
make modules -j"$(nproc)" SYSSRC=/host/linux-$KVER >/host/ko.log 2>&1
mkdir -p "$R/lib/modules/$KVER/extra"
cp *.ko "$R/lib/modules/$KVER/extra/"
strip --strip-debug "$R/lib/modules/$KVER/extra/"*.ko 2>/dev/null || true   # ~98M unstripped -> ~15M; --strip-debug keeps vermagic
# depmod so the freshly-copied open modules resolve. WITHOUT this, modprobe cannot find them and nothing
# loads nvidia at boot -> nvidia-smi fails "couldnt communicate with the driver" even though the .ko is present.
depmod -b "$R" "$KVER"
# auto-load the stack at boot (systemd-modules-load) so the GPU is up without manual modprobe.
mkdir -p "$R/etc/modules-load.d"
printf "nvidia\nnvidia-modeset\nnvidia-uvm\nnvidia-drm\n" > "$R/etc/modules-load.d/nvidia.conf"
echo "[gpu] open .ko installed: $(ls "$R/lib/modules/$KVER/extra/"*.ko | wc -l) modules ($(du -sh "$R/lib/modules/$KVER/extra" | cut -f1)); depmod + modules-load.d done"
'
# Verify: the open .ko exists in the rootfs AND its vermagic matches $KVER exactly (the whole point).
R="$W/rocky-img/rootfs"
KO="$R/lib/modules/$KVER/extra/nvidia.ko"
[ -f "$KO" ] || { echo "VERIFY-FAIL: nvidia.ko not in rootfs"; exit 1; }
VM=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
[ "$VM" = "$KVER" ] || { echo "VERIFY-FAIL: nvidia.ko vermagic '$VM' != $KVER"; exit 1; }
# These two would have caught the "nvidia-smi can't talk to the driver" failure at BUILD time:
grep -q "extra/nvidia.ko" "$R/lib/modules/$KVER/modules.dep" || { echo "VERIFY-FAIL: nvidia not in modules.dep (depmod did not run) — modprobe/boot-load would fail"; exit 1; }
[ -f "$R/etc/modules-load.d/nvidia.conf" ] || { echo "VERIFY-FAIL: no /etc/modules-load.d/nvidia.conf — nvidia would not auto-load at boot"; exit 1; }
echo "GPU-DOCKER-OK: open .ko vermagic=$VM in rootfs; in modules.dep; modules-load.d set"
