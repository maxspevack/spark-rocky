#!/bin/bash
# Layer 1 (non-destructive): Rocky 10.2 userspace nvbandwidth on the DGX kernel.
# Isolates the USERSPACE axis — Rocky el10 CUDA stack vs the host 59.2 GB/s reference,
# same 6.17-nvidia kernel + same (host-injected) driver. Runs on the Spark.
cat > /tmp/cuda-rhel10.repo <<'REPO'
[cuda-rhel10-sbsa]
name=cuda rhel10 sbsa
baseurl=https://developer.download.nvidia.com/compute/cuda/repos/rhel10/sbsa/
enabled=1
gpgcheck=0
REPO
docker run --rm --gpus all \
  -v /tmp/cuda-rhel10.repo:/etc/yum.repos.d/cuda.repo:ro \
  rockylinux/rockylinux:10 bash -c '
set -e
echo "[ctr] $(grep -m1 PRETTY_NAME /etc/os-release)"
dnf install -y -q gcc-c++ cmake git boost-devel cuda-toolkit-13-0 2>&1 | tail -1
export PATH=/usr/local/cuda/bin:$PATH
echo "[ctr] nvcc: $(nvcc --version | tail -1)"
echo "[ctr] driver (host-injected): $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader)"
cd /tmp && git clone -q https://github.com/NVIDIA/nvbandwidth && cd nvbandwidth
cmake -B build -DCMAKE_CUDA_COMPILER=$(command -v nvcc) -DCMAKE_CUDA_ARCHITECTURES=native >/dev/null 2>&1
cmake --build build -j$(nproc) >/dev/null 2>&1
echo "[ctr] === Rocky-userspace bandwidth (host ref = 59.2 GB/s) ==="
./build/nvbandwidth -t host_to_device_memcpy_ce 2>&1 | grep SUM
./build/nvbandwidth -t device_to_host_memcpy_ce 2>&1 | grep SUM
'
echo "ROCKY-NVBW-DONE"
