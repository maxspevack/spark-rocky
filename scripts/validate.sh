#!/bin/bash
# spark-rocky DOCTOR — one command to prove the whole box came up as we built it.
# Boot the image (USB or installed NVMe), log in, and run:  /root/validate.sh
#
# It proves three things and prints one PASS/FAIL:
#   1. provenance  — this IS a spark-rocky image, and it booted the kernel + driver (+ page size) we built
#   2. the stack   — open NVIDIA driver loaded, nvidia-smi works, a real CUDA kernel runs on the GPU
#   3. boot hygiene— the properties that make the image clean + fast are actually ACTIVE at runtime
set -uo pipefail
REL=/etc/spark-rocky-release
line(){ printf '%s\n' "============================================================"; }
sect(){ echo; echo "--- $1 ---"; }
FAIL=0
chk(){ if eval "$1" >/dev/null 2>&1; then echo "  ok: $2"; else echo "  !! $2"; FAIL=1; fi; }

line; echo " spark-rocky doctor · did this box come up as we built it?"; line

sect "1. provenance (what this image claims to be)"
EXP_K=""; EXP_D=""; EXP_PG=""
if [ -f "$REL" ]; then
  sed 's/^/  /' "$REL"
  EXP_K=$(awk -F= '/^kernel=/{print $2}' "$REL")
  EXP_D=$(awk -F= '/^driver=/{print $2}' "$REL")
  EXP_PG=$(awk -F= '/^page_size=/{print $2}' "$REL")
else
  echo "  !! $REL absent — cannot confirm this is a spark-rocky image"; FAIL=1
fi

sect "2. kernel + OS + open NVIDIA driver"
K=$(uname -r);  echo "  kernel:        $K"
OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"); echo "  os:            $OS"
DRV=$(modinfo nvidia 2>/dev/null | awk -F: '/^version:/{gsub(/[[:space:]]/,"",$2);print $2}')
echo "  nvidia driver: ${DRV:-NOT LOADED}"
chk '[ -n "$DRV" ]' "nvidia kernel module loaded"
[ -z "$EXP_K" ] || chk '[ "$K" = "$EXP_K" ]'   "running kernel matches the built kernel ($EXP_K)"
# #59: the kernel is a first-class rpm — the database must know the running kernel (truthful packaging).
KPKG=$(rpm -q kernel 2>/dev/null | head -1); echo "  kernel rpm:    ${KPKG:-NOT IN RPM DB}"
chk 'rpm -q kernel >/dev/null 2>&1' "kernel present in the rpm database (#59)"
# #77: the NVIDIA stack is rpm-owned too — the kmod package for THIS kernel, and the driver userspace.
KMODPKG="kmod-nvidia-open-$(uname -r | tr - _)"
chk 'rpm -q "$KMODPKG" >/dev/null 2>&1' "open kernel modules rpm-owned ($KMODPKG, #77)"
chk 'rpm -q nvidia-driver-userspace >/dev/null 2>&1' "driver userspace rpm-owned (nvidia-driver-userspace, #77)"
[ -z "$EXP_D" ] || chk '[ "$DRV" = "$EXP_D" ]' "running driver matches the built driver ($EXP_D)"
if [ -n "$EXP_PG" ]; then
  case "$EXP_PG" in 64k) WANT_PG=65536;; 4k) WANT_PG=4096;; *) WANT_PG="";; esac
  [ -z "$WANT_PG" ] || chk '[ "$(getconf PAGESIZE)" = "$WANT_PG" ]' "page size matches the built kernel ($EXP_PG = $WANT_PG bytes)"
fi

sect "3. nvidia-smi + GPU memory"
if nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | sed 's/^/  /'; then :
else echo "  !! nvidia-smi failed"; FAIL=1; fi
# GB10 has UNIFIED memory: nvidia-smi reports memory.total as [N/A] (no discrete VRAM) — which looks like a
# failure but isn't. Report the real GPU budget — the shared system RAM pool — instead of that confusing [N/A].
MEM=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
echo "  unified memory (GPU budget): ${MEM:-?} GiB"

sect "4. CUDA compute on the GPU"
# Self-contained: the doctor compiles + runs a real CUDA kernel ITSELF — no dependency on a sibling script
# (so it can never falsely report a missing helper script). nvcc-absent on a spark-rocky image is itself a FAIL.
if command -v nvcc >/dev/null 2>&1 || [ -x /usr/local/cuda/bin/nvcc ]; then
  cat > /tmp/va.cu <<'CU'
#include <cstdio>
__global__ void add(const float*a,const float*b,float*c,int n){int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) c[i]=a[i]+b[i];}
int main(){int n=1<<20; size_t sz=n*sizeof(float); float *a,*b,*c;
 cudaMallocManaged(&a,sz); cudaMallocManaged(&b,sz); cudaMallocManaged(&c,sz);
 for(int i=0;i<n;i++){a[i]=1.f; b[i]=2.f;}
 add<<<(n+255)/256,256>>>(a,b,c,n); cudaDeviceSynchronize();
 double err=0; for(int i=0;i<n;i++){double d=c[i]-3.0; err+=d*d;}
 cudaError_t e=cudaGetLastError();
 int dev; cudaGetDevice(&dev); cudaDeviceProp p; cudaGetDeviceProperties(&p,dev);
 printf("  device   : %s (compute %d.%d, %.1f GB)\n", p.name, p.major, p.minor, p.totalGlobalMem/1e9);
 printf("  vectorAdd: %d elems, sum-sq-err=%g, status=%s\n", n, err, cudaGetErrorString(e));
 return (e==cudaSuccess && err<1e-6)?0:1;}
CU
  if PATH=/usr/local/cuda/bin:$PATH nvcc -o /tmp/va /tmp/va.cu >/tmp/va.log 2>&1 && /tmp/va >>/tmp/va.log 2>&1; then
    grep -E "device|vectorAdd" /tmp/va.log
    echo "  ok: a real CUDA kernel compiled + ran on the GPU"
  else
    echo "  !! CUDA compile/run FAILED (log: /tmp/va.log):"; tail -3 /tmp/va.log | sed 's/^/     /'; FAIL=1
  fi
  # Managed-memory check (#63): an 8 GiB cudaMallocManaged alloc, written CPU-side and read GPU-side.
  # vectorAdd's tiny allocation missed the #65 class entirely (the 64k large-allocation fault shipped in
  # four releases under it); 8 GiB is the size the 2026-07-17 CLK validation used. Deliberately NOT the
  # ~90 GB serve-scale alloc — that is the serve-gate's job (#67); the doctor must stay safe to run on a
  # box with work loaded.
  cat > /tmp/mm.cu <<'CU'
#include <cstdio>
__global__ void bump(unsigned char*p,size_t n){size_t i=(size_t)blockIdx.x*blockDim.x+threadIdx.x; if(i<n) p[i]+=1;}
int main(){size_t n=8ull<<30; unsigned char*p; if(cudaMallocManaged(&p,n)!=cudaSuccess){printf("  managed-mem: ALLOC FAILED\n"); return 1;}
 for(size_t i=0;i<n;i+=4096) p[i]=7;
 bump<<<4096,256>>>(p,n); cudaDeviceSynchronize(); cudaError_t e=cudaGetLastError();
 int bad=(p[0]!=8)||(p[4096]!=8);
 printf("  managed-mem: 8 GiB cudaMallocManaged CPU-write/GPU-bump, status=%s, data=%s\n", cudaGetErrorString(e), bad?"WRONG":"ok");
 cudaFree(p); return (e==cudaSuccess && !bad)?0:1;}
CU
  if PATH=/usr/local/cuda/bin:$PATH nvcc -o /tmp/mm /tmp/mm.cu >/tmp/mm.log 2>&1 && /tmp/mm >>/tmp/mm.log 2>&1; then
    grep -E "managed-mem" /tmp/mm.log
    echo "  ok: 8 GiB managed memory round-trips CPU<->GPU (#63)"
  else
    echo "  !! managed-memory check FAILED (log: /tmp/mm.log) — the #65-class large-allocation detector:"; tail -3 /tmp/mm.log | sed 's/^/     /'; FAIL=1
  fi
else
  echo "  !! nvcc not found — cannot run the GPU CUDA check (a spark-rocky image ships CUDA; its absence is a failure)"; FAIL=1
fi

sect "5. boot hygiene (the properties that make the image clean + fast)"
chk 'grep -q nvidia-drm.modeset=0 /proc/cmdline' "nvidia-drm.modeset=0 active (no WQ_UNBOUND flood / console blackout)"
chk '! lsmod | grep -q "^mlx5_core"'             "mlx5_core not loaded (blacklisted — no missing-firmware dmesg flood)"
SWAP=$(awk '/^SwapTotal/{print $2}' /proc/meminfo 2>/dev/null)
chk '[ "${SWAP:-1}" = 0 ]'                       "swap off (SwapTotal=${SWAP:-?} kB; GB10 swap-on-overcommit hang prevention)"
NOISE=$(dmesg 2>/dev/null | grep -ciE 'mlx5.*(firmware|insufficient power)|WQ_UNBOUND')
chk '[ "${NOISE:-1}" = 0 ]'                      "dmesg clean of the known regressions (mlx5-firmware / WQ_UNBOUND): ${NOISE:-?} hit(s)"

line
if [ "$FAIL" = 0 ]; then
  echo " RESULT: PASS"
  echo " Rocky + stock kernel $K + open driver $DRV drives the GB10 on this box, and the image is clean."
else
  echo " RESULT: FAIL"
  echo " Something above did not come up as expected — see the failed checks (!!) above."
fi
line
