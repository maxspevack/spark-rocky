#!/bin/bash
# Proof of life for Rocky + the pinned upstream kernel + NVIDIA/CUDA on the DGX Spark (GB10).
# Reports uname -r (version-agnostic) so it works against any pinned KVER. Run on the booted Rocky
# (USB-live or bare-metal). Produces a shareable status snapshot.
set +e
echo "=================== SPARK / ROCKY PROOF OF LIFE ==================="
echo "date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host:        $(hostname)"
echo "boot device: $(findmnt -no SOURCE / )   (bare metal = /dev/nvme0n1p2)"
echo "--- OS + kernel ---"
grep PRETTY_NAME /etc/os-release; echo "kernel: $(uname -r)"
echo "--- network (SSH reachable) ---"
ip -br a | grep -v "^lo" | awk '{print $1, $2, $3}'
echo "--- NVIDIA driver / GPU ---"
# memory.total reads [N/A] on the GB10 — NORMAL, not broken: unified memory means the GPU has no
# dedicated VRAM pool for nvidia-smi to report (the 2026-07-22 lesson; misreading it cost a "GPU
# wedged" false alarm). The CUDA vectorAdd below is the real memory proof.
nvidia-smi --query-gpu=name,driver_version,memory.total,temperature.gpu --format=csv 2>/dev/null || nvidia-smi 2>&1 | head -12
echo "--- loaded nvidia modules ---"; lsmod | grep nvidia
echo "--- CUDA toolkit ---"; (nvcc --version 2>/dev/null | tail -2) || echo "nvcc not in PATH"
echo "--- CUDA compute test (compile + run vectorAdd on the GPU) ---"
cat > /tmp/vectoradd.cu <<'CU'
#include <cstdio>
__global__ void add(const float*a,const float*b,float*c,int n){int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) c[i]=a[i]+b[i];}
int main(){int n=1<<20; size_t sz=n*sizeof(float); float *a,*b,*c;
 cudaMallocManaged(&a,sz); cudaMallocManaged(&b,sz); cudaMallocManaged(&c,sz);
 for(int i=0;i<n;i++){a[i]=1.f; b[i]=2.f;}
 add<<<(n+255)/256,256>>>(a,b,c,n); cudaDeviceSynchronize();
 double err=0; for(int i=0;i<n;i++){double d=c[i]-3.0; err+=d*d;}
 cudaError_t e=cudaGetLastError();
 int dev; cudaGetDevice(&dev); cudaDeviceProp p; cudaGetDeviceProperties(&p,dev);
 printf("device   : %s (compute %d.%d, %.1f GB)\n", p.name, p.major, p.minor, p.totalGlobalMem/1e9);
 printf("vectorAdd: %d elems, sum-sq-err=%g, status=%s\n", n, err, cudaGetErrorString(e));
 return (e==cudaSuccess && err<1e-6)?0:1;}
CU
rm -f /tmp/vectoradd   # so a stale binary can't survive a failed recompile and report a false PASS
PATH=/usr/local/cuda/bin:$PATH nvcc -o /tmp/vectoradd /tmp/vectoradd.cu 2>&1 | tail -3
if [ -x /tmp/vectoradd ] && /tmp/vectoradd; then echo "CUDA COMPUTE: PASS"; else echo "CUDA COMPUTE: FAIL"; fi
echo "=================================================================="
