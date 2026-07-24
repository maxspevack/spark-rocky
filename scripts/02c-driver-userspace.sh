#!/bin/bash
# Stage 1c: install matched $DRIVER_VER driver USERSPACE into the rootfs via the .run (--no-kernel-modules),
# sidestepping the dnf dkms/kmod dependency chain. The open .ko (02b, in extra/) is the kernel side.
# Parameterized via config/versions.env. Reuses the .run that 02b downloaded to $W/driver-610.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"          # DRIVER_VER, DRIVER_SHA256, ROCKY_RELEASEVER (the userspace-rpm installroot, #77)
W="${W:-$(dirname "$HERE")}"
[ -d "$W/rocky-img/rootfs" ] || { echo "FATAL: rootfs missing — run 02-build-rootfs.sh first"; exit 1; }

mkdir -p "$W/.dnf-cache"   # persistent dnf cache shared with 01/02b/03 (#70 build-speed)
docker run --rm --privileged -v "$W":/host -v "$W/.dnf-cache":/var/cache/dnf -e DRIVER_VER="$DRIVER_VER" -e DRIVER_SHA256="$DRIVER_SHA256" -e RV="$ROCKY_RELEASEVER" rockylinux/rockylinux:10 bash -c '
set -euo pipefail
R=/host/rocky-img/rootfs
RUN=NVIDIA-Linux-aarch64-$DRIVER_VER.run
SRC=/host/driver-610/$RUN
[ -f "$SRC" ] || { echo "FATAL: $SRC missing — run 02b first (it downloads the .run)"; exit 1; }
# Fail-closed: same pinned-hash gate as 02b (each stage is standalone-runnable; verify at point of use).
echo "$DRIVER_SHA256  $SRC" | sha256sum -c - >/dev/null 2>&1 \
  || { echo "FATAL: $SRC sha256 != pinned DRIVER_SHA256 (versions.env) — refusing to install"; exit 1; }
echo keepcache=1 >> /etc/dnf/dnf.conf
dnf install -y -q rpm-build cpio rsync findutils >/dev/null 2>&1   # userspace-rpm build deps (#77)
cp "$SRC" "$R/tmp/"
for m in proc sys dev dev/pts; do mkdir -p "$R/$m"; mount --bind "/$m" "$R/$m" 2>/dev/null || true; done
# Snapshot BEFORE: the path-diff after the chroot install is the GROUND-TRUTH payload manifest (#77) —
# what nvidia-installer actually laid down (files + symlinks, real perms/targets). No interpretation of
# the .run manifest'"'"'s ~30 file types, no drift on a driver bump: the diff regenerates per build.
# /var/log + /tmp + the bind mounts excluded: installer logs and scratch are not payload.
snap(){ (cd "$R" && find . \( -path ./proc -o -path ./sys -o -path ./dev -o -path ./tmp -o -path ./var/log \) -prune -o -print | sort); }
snap > /tmp/pre.list
echo "=== running .run userspace-only inside the rootfs chroot ==="
# Inner pipefail (review M6): without it the pipeline status is tail-of-pipe (always 0) and a failed
# or partial .run install reports success — upgrade-metal gets this right via its own set -o pipefail.
chroot "$R" /bin/bash -c "set -o pipefail; cd /tmp && sh $RUN --no-kernel-modules --no-questions --ui=none --no-x-check --no-nouveau-check --install-libglvnd 2>&1 | tail -12"
for m in dev/pts dev sys proc; do umount -l "$R/$m" 2>/dev/null || true; done
snap > /tmp/post.list
comm -13 /tmp/pre.list /tmp/post.list > /tmp/new.list
# The diff is only ground truth on a FRESH rootfs (the 02 -> 02b -> 02c order): a re-run over a rootfs
# that already carries the userspace sees zero new paths. Fail with the actual remedy.
[ -s /tmp/new.list ] || { echo "VERIFY-FAIL: the .run install produced no new paths (#77) — the rootfs already carried the userspace. The snapshot manifest needs a fresh rootfs: rerun from 02-build-rootfs.sh."; exit 1; }
echo "[userspace-rpm] $(wc -l < /tmp/new.list) new paths from the .run install"
# Stage the payload into a buildroot (rsync preserves symlinks/perms/dirs), list real entries for %files.
BR=/tmp/us-buildroot; rm -rf "$BR"; mkdir -p "$BR"
rsync -a --files-from=/tmp/new.list "$R/" "$BR/" 2>/dev/null
find "$BR" \( -type f -o -type l \) | sed "s|^$BR||" > /tmp/us.files
[ -s /tmp/us.files ] || { echo "VERIFY-FAIL: empty userspace buildroot (#77)"; exit 1; }
cat > /tmp/us.spec <<SPEC
Name: nvidia-driver-userspace
Version: $DRIVER_VER
Release: 1
Summary: NVIDIA driver userspace + GSP firmware (spark-rocky, packaged from the pinned .run payload)
License: NVIDIA Proprietary
AutoReqProv: no
%description
The userspace half of the NVIDIA driver ($DRIVER_VER) — libraries, tools, GSP firmware —
packaged by the spark-rocky pipeline (02c) from the sha256-pinned .run installer payload,
captured as the rootfs path-diff of the actual install. Pairs with kmod-nvidia-open-<kver>.
%files
SPEC
sed "s/ /?/g" /tmp/us.files >> /tmp/us.spec   # rpm %files: ? glob survives any odd char; nvidia paths have none, belt only
rpmbuild -bb --define "_topdir /tmp/us-rpm" --buildroot "$BR" /tmp/us.spec >/host/userspace-rpm.log 2>&1 \
  || { echo "VERIFY-FAIL: userspace rpm build failed (#77) — see userspace-rpm.log"; exit 1; }
USRPM=$(ls /tmp/us-rpm/RPMS/aarch64/nvidia-driver-userspace-*.rpm | head -1)
[ -n "$USRPM" ] || { echo "VERIFY-FAIL: no userspace rpm produced (#77)"; exit 1; }
cp "$USRPM" /host/
sed -i "/^USRPM=/d" /host/build.env 2>/dev/null || true
echo "USRPM=$(basename $USRPM)" >> /host/build.env
echo "[userspace-rpm] $(basename $USRPM) ($(du -h $USRPM | cut -f1))"
# Install the rpm OVER the .run-laid files (identical bytes; rpm takes ownership — same pattern as the
# kernel rpm over unowned paths). tsflags=noscripts for symmetry; ldconfig already ran via the .run,
# and 05 pre-builds ld.so.cache regardless.
dnf install -y -q --installroot="$R" --releasever=$RV --nogpgcheck --setopt=tsflags=noscripts "$USRPM" >>/host/userspace-rpm.log 2>&1 \
  || { echo "VERIFY-FAIL: userspace rpm install into rootfs failed (#77)"; exit 1; }
rpm --root "$R" -q nvidia-driver-userspace >/dev/null 2>&1 || { echo "VERIFY-FAIL: userspace rpm not in rootfs rpm db (#77)"; exit 1; }
'
# Verify userspace actually landed in the rootfs.
R="$W/rocky-img/rootfs"
[ -x "$R/usr/bin/nvidia-smi" ] || { echo "VERIFY-FAIL: nvidia-smi not in rootfs"; exit 1; }
ls "$R"/usr/lib64/libcuda.so* >/dev/null 2>&1 || { echo "VERIFY-FAIL: libcuda.so not in rootfs"; exit 1; }
# #77: the userspace must be rpm-owned — rpm -qf answers for the core artifacts.
rpm --root "$R" -qf /usr/bin/nvidia-smi >/dev/null 2>&1 || { echo "VERIFY-FAIL: nvidia-smi not rpm-owned (#77)"; exit 1; }
echo "DRV-USERSPACE-OK: nvidia-smi + libcuda in rootfs, rpm-owned ($(du -sh "$R" | cut -f1))"
