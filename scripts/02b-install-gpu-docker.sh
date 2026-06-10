#!/bin/bash
# Stage 1b: add the GPU stack + container runtime into the Rocky rootfs.
# - docker + nvidia-container-toolkit (the benchmark runs vLLM in a container)
# - the 610 open driver: build .ko against our 6.18.34 tree, install into rootfs + el10 userspace
docker run --rm -v /home/max:/host rockylinux/rockylinux:10 bash -c '
set -e
R=/host/rocky-img/rootfs
dnf install -y -q make gcc kmod findutils tar xz wget >/dev/null 2>&1

echo "[gpu] container runtime repos into rootfs"
cat >"$R/etc/yum.repos.d/docker.repo" <<EOF
[docker-ce]
name=docker-ce
baseurl=https://download.docker.com/linux/centos/10/aarch64/stable
enabled=1
gpgcheck=0
EOF
curl -s -o "$R/etc/yum.repos.d/nvidia-container-toolkit.repo" https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo 2>/dev/null || true
sed -i "s/gpgcheck=1/gpgcheck=0/g; s/repo_gpgcheck=1/repo_gpgcheck=0/g" "$R/etc/yum.repos.d/nvidia-container-toolkit.repo" 2>/dev/null || true
dnf -y --installroot="$R" --releasever=10 --setopt=install_weak_deps=False install \
  docker-ce docker-ce-cli containerd.io nvidia-container-toolkit >/host/rocky-img/gpu.log 2>&1 \
  && echo "[gpu] docker+toolkit OK" || { echo "[gpu] docker/toolkit FAILED"; tail -8 /host/rocky-img/gpu.log; }

echo "[gpu] driver userspace (el10 610, userspace only) into rootfs"
dnf -y --installroot="$R" --releasever=10 --setopt=install_weak_deps=False install \
  nvidia-driver-cuda-libs nvidia-driver-libs >>/host/rocky-img/gpu.log 2>&1 \
  && echo "[gpu] driver userspace OK" || echo "[gpu] driver-userspace step needs refine (see gpu.log)"

echo "[gpu] building + installing open .ko into rootfs"
cd /tmp
RUN=NVIDIA-Linux-aarch64-610.43.02.run
curl -fsSL -m180 -o "$RUN" "https://us.download.nvidia.com/XFree86/aarch64/610.43.02/$RUN" 2>/dev/null
sh "$RUN" -x >/dev/null 2>&1
cd NVIDIA-Linux-aarch64-610.43.02/kernel-open
make modules -j"$(nproc)" SYSSRC=/host/kbuild/linux-6.18.34 SYSOUT=/host/kbuild/linux-6.18.34 >/tmp/ko.log 2>&1 \
  && { mkdir -p "$R/lib/modules/6.18.34/extra"; cp *.ko "$R/lib/modules/6.18.34/extra/"; echo "[gpu] open .ko installed: $(ls *.ko | wc -l)"; } \
  || { echo "[gpu] open module build FAILED"; tail -6 /tmp/ko.log; }
echo "[gpu] rootfs size: $(du -sh $R 2>/dev/null | cut -f1)"
'
echo GPU-DOCKER-DONE
