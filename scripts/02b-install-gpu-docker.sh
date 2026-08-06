#!/bin/bash
# Stage 1b: add the GPU stack + container runtime + open driver kernel module into the Rocky rootfs.
# - docker + nvidia-container-toolkit (the benchmark runs vLLM in a container)
# - the open driver: build .ko against our $KVER tree, install into the rootfs; add el10 driver userspace libs
# Parameterized via config/versions.env. Non-destructive: writes to $W/rocky-img + $W/driver-610.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # KVER, DRIVER_VER, DRIVER_SHA256, ROCKY_RELEASEVER (+ KERNEL_SOURCE/CLK_COMMIT for the gate)
W="${W:-$(dirname "$HERE")}"
source "$HERE/lib/build-env-gate.sh"   # fail-closed staleness gate on 01's build.env (one impl — audit #70 C1)
[ -d "$W/rocky-img/rootfs" ] || { echo "FATAL: rootfs missing — run 02-build-rootfs.sh first"; exit 1; }

mkdir -p "$W/.dnf-cache"   # persistent dnf cache shared with 01/03 (#70 build-speed)
docker run --rm -v "$W":/host -v "$W/.dnf-cache":/var/cache/dnf -e KVER="$KVER" -e DRIVER_VER="$DRIVER_VER" -e DRIVER_SHA256="$DRIVER_SHA256" -e RV="$ROCKY_RELEASEVER" rockylinux/rockylinux:10 bash -c '
set -euo pipefail
R=/host/rocky-img/rootfs
echo keepcache=1 >> /etc/dnf/dnf.conf   # persists in the mounted /var/cache/dnf across builds (#70)
dnf install -y -q make gcc kmod findutils tar xz wget curl rpm-build cpio >/dev/null 2>&1   # rpm-build/cpio: the kmod rpm (#77)

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

# No dnf driver-userspace here: it pulled whatever version the NVIDIA repo
# served that day into a pinned image -- a pin violation, and a moving baseline
# under the 02c path-diff. 02c installs the pinned .run userspace, rpm-owned.
# NOTE: this whole container script is ONE single-quoted string handed to
# bash -c by the docker run at the top of the file. A single quote character
# anywhere in here -- comments included -- ends that string early and breaks
# the parse. No contractions, no quoted words, until the closing quote.

echo "[gpu] ensure driver .run downloaded + extracted at /host/driver-610 (shared with 02c/03)"
RUN=NVIDIA-Linux-aarch64-$DRIVER_VER.run
DRV=/host/driver-610/NVIDIA-Linux-aarch64-$DRIVER_VER
mkdir -p /host/driver-610; cd /host/driver-610
[ -f "$RUN" ] || curl -fsSL -m300 -o "$RUN" "https://us.download.nvidia.com/XFree86/aarch64/$DRIVER_VER/$RUN"
# Fail-closed: the .run must match the pinned DRIVER_SHA256 (versions.env) before anything consumes it.
echo "$DRIVER_SHA256  $RUN" | sha256sum -c - >/dev/null 2>&1 \
  || { echo "FATAL: $RUN sha256 != pinned DRIVER_SHA256 (versions.env) — refusing to extract"; exit 1; }
echo "[gpu] .run verified against pinned DRIVER_SHA256"
[ -d "$DRV" ] || sh "$RUN" -x >/dev/null 2>&1

echo "[gpu] building the open .ko (against $KVER, el10 gcc-14)"
cd "$DRV/kernel-open"
make clean >/dev/null 2>&1 || true
make modules -j"$(nproc)" SYSSRC=/host/linux-$KVER >/host/ko.log 2>&1
# Package the .ko set as a kmod rpm (#77) and dnf-install it — /lib/modules becomes 100% rpm-owned
# (kernel rpm + this). The kernel version rides the NAME (kernel-package convention: per-kver packages
# coexist side-by-side, e.g. on the metal next to the fallback kernel); the driver version is the rpm
# Version. AutoReqProv off: nvidia .ko must not generate wild auto-deps. No %post — the pipeline owns
# depmod explicitly, same treatment as the kernel rpm. Stripped before packaging (~98M -> ~15M).
KSAN=$(echo "$KVER" | tr - _)
BR=/tmp/kmod-buildroot; rm -rf "$BR"; mkdir -p "$BR/lib/modules/$KVER/extra" "$BR/etc/modules-load.d"
cp *.ko "$BR/lib/modules/$KVER/extra/"
strip --strip-debug "$BR/lib/modules/$KVER/extra/"*.ko
# Size-gate the strip (review NIT-2): a silent strip failure ships ~98M-per-module debug-laden .ko.
KOSZ=$(du -sm "$BR/lib/modules/$KVER/extra" | cut -f1)
[ "$KOSZ" -lt 100 ] || { echo "VERIFY-FAIL: .ko set is ${KOSZ}M after strip (expected ~15M) — strip did not take"; exit 1; }
# The boot auto-load config rides the kmod rpm too — kernel-side nvidia config, rpm-owned.
printf "nvidia\nnvidia-modeset\nnvidia-uvm\nnvidia-drm\n" > "$BR/etc/modules-load.d/nvidia.conf"
cat > /tmp/kmod.spec <<SPEC
Name: kmod-nvidia-open-$KSAN
Version: $DRIVER_VER
Release: 1
Summary: NVIDIA open kernel modules for kernel $KVER (spark-rocky, built from unmodified source)
License: MIT AND GPL-2.0-only
AutoReqProv: no
Requires: kernel = $KSAN
%description
The open NVIDIA GPU kernel modules ($DRIVER_VER), built unmodified against the exact
kernel $KVER by the spark-rocky pipeline (02b), plus the boot auto-load config.
Installed to /lib/modules/$KVER/extra/.
%files
/lib/modules/$KVER/extra/*.ko
%config /etc/modules-load.d/nvidia.conf
SPEC
rpmbuild -bb --define "_topdir /tmp/kmod-rpm" --buildroot "$BR" /tmp/kmod.spec >/host/kmod-rpm.log 2>&1 \
  || { echo "VERIFY-FAIL: kmod rpm build failed (#77) — see kmod-rpm.log"; exit 1; }
KMODRPM=$(ls /tmp/kmod-rpm/RPMS/aarch64/kmod-nvidia-open-*.rpm | head -1)
[ -n "$KMODRPM" ] || { echo "VERIFY-FAIL: no kmod rpm produced (#77)"; exit 1; }
cp "$KMODRPM" /host/
# Hand the kmod rpm name downstream (upgrade-metal, 05 vend) via build.env — same channel as KRPM.
# sed-then-append: a 02b re-run must not accumulate duplicate lines.
sed -i "/^KMODRPM=/d" /host/build.env 2>/dev/null || true
echo "KMODRPM=$(basename $KMODRPM)" >> /host/build.env
echo "[gpu] kmod rpm: $(basename $KMODRPM) ($(du -h $KMODRPM | cut -f1))"
dnf install -y -q --installroot="$R" --releasever=$RV --nogpgcheck --setopt=tsflags=noscripts "$KMODRPM" \
  >>/host/ko.log 2>&1 || { echo "VERIFY-FAIL: kmod rpm install into rootfs failed (#77)"; exit 1; }
rpm --root "$R" -q "kmod-nvidia-open-$KSAN" >/dev/null 2>&1 || { echo "VERIFY-FAIL: kmod rpm not in rootfs rpm db (#77)"; exit 1; }
# depmod so the open modules resolve. WITHOUT this, modprobe cannot find them and nothing
# loads nvidia at boot -> nvidia-smi fails "couldnt communicate with the driver" even though the .ko is present.
depmod -b "$R" "$KVER"
# (the boot auto-load config /etc/modules-load.d/nvidia.conf arrives WITH the kmod rpm — rpm-owned)
echo "[gpu] open .ko installed via kmod rpm: $(ls "$R/lib/modules/$KVER/extra/"*.ko | wc -l) modules ($(du -sh "$R/lib/modules/$KVER/extra" | cut -f1)); depmod + modules-load.d done"
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
