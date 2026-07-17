#!/bin/bash
# Turn the box-local build output into a VENDABLE, traceable artifact: harden it for handing to
# other people, stamp provenance INTO the image, introspect a build manifest, and compress.
#
# FAIL-CLOSED by design (Bruce/Gafton): every hardening step is RE-VERIFIED against the mounted
# image, and if any did not take the script aborts and emits NO checksum. You must never hand a
# checksum (let alone a signature) to an artifact you did not verify.
#
# Runs on the Spark (aarch64 — it chroots into the image). Operates on a COPY; the validated
# build image is never touched. Provenance (git) is passed in by env because the box checkout may
# be an rsync copy with no .git.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../config/versions.env"                 # KVER, DRIVER_VER, ROCKY_RELEASEVER, KERNEL_SHA256, PAGE_SIZE
W="${W:-$(dirname "$HERE")}"
# build.env: 01's resolved-KVER handoff (clk derives the release, e.g. 6.18.38-clk). Fail closed on
# staleness — the release stamp must never carry a KVER from a different source/pin than what built.
if [ -f "$W/build.env" ]; then
  PIN_KVER=$KVER; source "$W/build.env"
  [ "${BUILD_KERNEL_SOURCE:-}" = "$KERNEL_SOURCE" ] || { echo "FATAL: stale build.env (built from '${BUILD_KERNEL_SOURCE:-?}', pin is '$KERNEL_SOURCE') — rerun 01-build-kernel.sh"; exit 1; }
  [ "$KERNEL_SOURCE" != kernelorg ] || [ "$KVER" = "$PIN_KVER" ] || { echo "FATAL: stale build.env (KVER $KVER != pinned $PIN_KVER) — rerun 01-build-kernel.sh"; exit 1; }
  [ "$KERNEL_SOURCE" != clk ] || [ "${BUILD_CLK_COMMIT:-}" = "$CLK_COMMIT" ] || { echo "FATAL: stale build.env (CLK_COMMIT moved) — rerun 01-build-kernel.sh"; exit 1; }
fi
SRC="${SRC:-$W/rocky-img/rocky-gb10.img}"             # derive like 04 derives IMG (was a hardcoded mismatch)
OUTDIR="${OUTDIR:-$W/vend}"
INIT_PW="${INIT_PW:-rocky}"                            # documented console password (root/rocky); no forced reset (test image)
GIT_DESC="${GIT_DESC:-unknown}"                        # passed from the dev box
GIT_COMMIT="${GIT_COMMIT:-unknown}"
RELDATE="${RELDATE:-$(date -u +%Y%m%d)}"
DATE_UTC="${DATE_UTC:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
STAMP="spark-rocky-live-aarch64-${KVER}-${RELDATE}"

[ "$(id -u)" = 0 ]        || { echo "FATAL: must run as root (loop-mounts an image)"; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "FATAL: 05 chroots into an aarch64 image; run on the Spark (or register qemu-user-static)"; exit 1; }
[ -f "$SRC" ]             || { echo "FATAL: source image not found: $SRC (run 01-04 first, or pass SRC=)"; exit 1; }
command -v xz >/dev/null 2>&1 || dnf install -y -q xz 2>/dev/null || true

mkdir -p "$OUTDIR"
WORK="$OUTDIR/${STAMP}.raw"
echo "=== copy the build image (the validated original is never touched) ==="
cp -f --reflink=auto "$SRC" "$WORK"

# --- mount, waiting for the partition node (losetup -P creates it asynchronously via udev) ---
LOOP=$(losetup --find --show -P "$WORK")
for _ in $(seq 1 50); do [ -e "${LOOP}p2" ] && break; sleep 0.2; done
[ -e "${LOOP}p2" ] || { echo "FATAL: ${LOOP}p2 never appeared"; losetup -d "$LOOP"; exit 1; }
MNT=$(mktemp -d)
mount "${LOOP}p2" "$MNT"
mountpoint -q "$MNT" || { echo "FATAL: mount of ${LOOP}p2 failed"; losetup -d "$LOOP"; rmdir "$MNT"; exit 1; }
cleanup(){ umount "$MNT" 2>/dev/null||true; losetup -d "$LOOP" 2>/dev/null||true; rmdir "$MNT" 2>/dev/null||true; }
trap cleanup EXIT

echo "=== harden for vending ==="
rm -f "$MNT/root/.ssh/authorized_keys"                                    # 1. builder trust
install -d -m755 "$MNT/etc/ssh/sshd_config.d"                             # 2. close the network root-password race (Bruce CRITICAL)
cat > "$MNT/etc/ssh/sshd_config.d/99-spark-rocky.conf" <<EOF
# spark-rocky vended image: root password (root/rocky) works at the CONSOLE only. No password auth
# over the network (closes the "first connector with the default password gets root" race).
# Key-based root is allowed for headless use once you add your own key to /root/.ssh/authorized_keys.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
chroot "$MNT" /bin/bash -c "echo 'root:$INIT_PW' | chpasswd"                      # 3. documented console password root/rocky (no forced reset — Max: don't annoy validators)
rm -f "$MNT"/etc/ssh/ssh_host_*                                           # 4. per-box host identity
echo uninitialized > "$MNT/etc/machine-id"            # regenerate a unique ID per box on first boot,
# but mask the commit service: on a ro-root boot an empty/transient machine-id triggers a bind-mount
# commit that HUNG boot for 90s and timed out. The transient /run id is fine for a live image.
ln -sf /dev/null "$MNT/etc/systemd/system/systemd-machine-id-commit.service"
rm -f "$MNT/root/.bash_history"; rm -f "$MNT"/home/*/.bash_history 2>/dev/null || true   # 5. build residue
rm -rf "$MNT"/tmp/* "$MNT"/var/tmp/* 2>/dev/null || true
find "$MNT/root" -maxdepth 2 -name '*.run' -delete 2>/dev/null || true
install -m755 "$HERE/validate.sh" "$MNT/root/validate.sh"                  # 6. one-command validator (repos verified in the gate)
cat > "$MNT/etc/spark-rocky-release" <<EOF                                # 8. provenance INSIDE the image
spark-rocky live image
build_id=${STAMP}
git_describe=${GIT_DESC}
git_commit=${GIT_COMMIT}
kernel=${KVER}
kernel_source=${KERNEL_SOURCE}
clk_commit=${CLK_COMMIT:-}
page_size=${PAGE_SIZE}
driver=${DRIVER_VER}
rocky_releasever=${ROCKY_RELEASEVER}
built_utc=${DATE_UTC}
builder_arch=$(uname -m)
EOF
[ "${SBOM:-0}" = 1 ] && rpm -qa --root "$MNT" --qf '%{NEVRA}\n' 2>/dev/null | sort > "$OUTDIR/${STAMP}.packages.txt" \
  && echo "  - SBOM package list written (SBOM=1)"

# 7. pre-build the dynamic linker cache. Without this the FIRST boot runs a COLD ldconfig that scans the
# whole CUDA tree and serializes the entire boot behind it for ~63s (measured; a warm run is <1s). Build
# it here so we ship a current /etc/ld.so.cache and first boot is fast.
echo "=== pre-build linker cache (chroot ldconfig — kills the 63s first-boot cold rebuild) ==="
chroot "$MNT" /sbin/ldconfig; echo "  - ld.so.cache: $(chroot "$MNT" ldconfig -p 2>/dev/null | wc -l) libs cached"

# --- introspect for the manifest WHILE mounted (generated, never hand-typed -> can't drift) ---
OS_VER=$(. "$MNT/etc/os-release" 2>/dev/null; echo "${VERSION:-unknown}")
CUDA_PKGS=$(rpm -qa --root "$MNT" 2>/dev/null | grep -iE '^cuda-' | sort | tr '\n' ' ')
KMODS=$(ls "$MNT"/lib/modules/ 2>/dev/null | tr '\n' ' ')
CFG="$W/config-$KVER"   # the RESOLVED config 01 built (config-$KVER, e.g. config-6.18.35). NO glob fallback: a 05-only re-run without 01 must FAIL the gate below, never silently sign a guessed .config identity (Gafton)
WANT_PG=$([ "$PAGE_SIZE" = 64k ] && echo "CONFIG_ARM64_64K_PAGES=y" || echo "CONFIG_ARM64_4K_PAGES=y")   # the page-size symbol the pin demands
CFG_SHA=$([ -f "$CFG" ] && sha256sum "$CFG" | cut -d' ' -f1 || echo unknown)

# --- FAIL-CLOSED gate: re-check the REAL image state; abort before compressing if anything failed ---
echo "=== verify hardening actually took (fail-closed) ==="
VERR=0
chk(){ if eval "$1"; then echo "  ok: $2"; else echo "  VERIFY-FAIL: $2"; VERR=1; fi; }
chk '[ ! -e "$MNT/root/.ssh/authorized_keys" ]'                          "builder authorized_keys removed"
chk '[ -f "$MNT/etc/ssh/sshd_config.d/99-spark-rocky.conf" ]'            "sshd network-root lockdown present"
chk 'chroot "$MNT" passwd -S root 2>/dev/null | grep -q "^root P "'        "root password set (root/rocky, console-only)"
chk '! ls "$MNT"/etc/ssh/ssh_host_* >/dev/null 2>&1'                     "ssh host keys cleared"
chk 'grep -qx uninitialized "$MNT/etc/machine-id"'                       "machine-id set to regenerate (uninitialized)"
chk '[ -L "$MNT/etc/systemd/system/systemd-machine-id-commit.service" ]' "machine-id-commit masked (no 90s boot hang)"
chk '[ ! -e "$MNT/root/.bash_history" ]'                                 "build-host shell history removed"
UNVERIFIED=""; for rf in "$MNT"/etc/yum.repos.d/*.repo; do [ -f "$rf" ] || continue; grep -q '^gpgcheck=1' "$rf" && continue; grep -q '^repo_gpgcheck=1' "$rf" && continue; UNVERIFIED="$UNVERIFIED $(basename "$rf")"; done
chk '[ -z "$UNVERIFIED" ]'                                               "every repo verifies signatures (gpgcheck or repo_gpgcheck)${UNVERIFIED:+ — UNVERIFIED:$UNVERIFIED}"
chk '[ -x "$MNT/root/validate.sh" ]'                                     "validate.sh installed"
chk '[ -x "$MNT/root/proof-of-life.sh" ]'                                "proof-of-life.sh present (validate.sh CUDA check)"
chk '[ -x "$MNT/root/templog.sh" ]'                                      "templog.sh present (forensic thermal/mem trace)"
# boot-hygiene properties that DEFINE the image (the 2026-06-13 hardening) — a release must carry every one
chk 'grep -q "nvidia-drm.modeset=0" "$MNT/boot/grub2/grub.cfg"'           "boot: nvidia-drm.modeset=0 in grub (kills WQ_UNBOUND flood + console blackout) — checks the root-partition grub.cfg (05 mounts only p2); 04 verifies the identical EFI copy references the kernel"
chk 'grep -q "blacklist mlx5_core" "$MNT/etc/modprobe.d/blacklist-mlx5.conf"'  "boot: mlx5_core blacklisted (no missing-firmware dmesg flood, #30)"
chk '[ "$(readlink "$MNT/etc/systemd/system/swap.target")" = /dev/null ]'      "boot: swap.target masked (GB10 swap-on-overcommit hang)"
chk '[ "$(readlink "$MNT/etc/systemd/system/systemd-firstboot.service")" = /dev/null ]'  "boot: systemd-firstboot masked (no interactive tz prompt at first boot)"
chk 'grep -q -- "--autologin root" "$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf"'  "boot: console autologin configured"
chk '[ -s "$MNT/etc/spark-rocky-release" ]'                              "provenance stamp written"
chk '[ ! -e "$MNT/etc/spark-rocky-debug-hatch" ]'                        "no DEBUG hatch marker (a DEBUG build is un-releasable)"
chk '[ -f "$W/config-$KVER" ]'                                           "resolved config-$KVER present (manifest hashes the real build config, not a guessed base glob)"
chk 'grep -q "$WANT_PG" "$CFG"'                                          "page size matches the pin: $PAGE_SIZE ($WANT_PG) — a 64k pin cannot ship a 4k image"

sync; cleanup; trap - EXIT
[ "$VERR" = 0 ] || { echo "ABORT: hardening verification failed — NOT compressing, NOT emitting a checksum."; rm -f "$WORK"; exit 1; }

echo "=== inner (uncompressed) image hash ==="
INNER_SHA=$(sha256sum "$WORK" | cut -d' ' -f1)
echo "=== compress for download (xz multithreaded) ==="
rm -f "$WORK.xz"; xz -T0 -6 -v "$WORK"
ART="$WORK.xz"
OUTER_SHA=$(sha256sum "$ART" | cut -d' ' -f1)

MANIFEST="$OUTDIR/${STAMP}.BUILD-MANIFEST.txt"
cat > "$MANIFEST" <<EOF
spark-rocky live image — build manifest
========================================
build_id            : ${STAMP}
artifact            : $(basename "$ART")
artifact_sha256     : ${OUTER_SHA}
inner_image_sha256  : ${INNER_SHA}
git_describe        : ${GIT_DESC}
git_commit          : ${GIT_COMMIT}
built_utc           : ${DATE_UTC}
builder_arch        : $(uname -m)

contents (introspected from the image)
--------------------------------------
os                  : ${OS_VER}
kernel modules dir  : ${KMODS}
kernel source       : ${KERNEL_SOURCE} $([ "$KERNEL_SOURCE" = clk ] && echo "(CIQ Linux Kernel, ctrliq/kernel-src-tree @ ${CLK_COMMIT:0:12})" || echo "(kernel.org tarball, GPG-verified SHA256 pin)")
kernel release      : ${KVER} (uname -r; the -clk suffix = CLK lineage)
page size           : ${PAGE_SIZE} (CONFIG_ARM64 page-size choice, pinned in versions.env)
nvidia driver       : ${DRIVER_VER} (open kernel module, built in rockylinux:10 / gcc 14.3.1)
cuda packages       : ${CUDA_PKGS:-none}
kernel .config      : $([ -f "$CFG" ] && basename "$CFG" || echo unknown)  (sha256 ${CFG_SHA})

security posture
----------------
selinux             : DISABLED (kernel cmdline selinux=0 overrides the permissive config file)
root ssh            : no password auth over the network; key-only (prohibit-password). Console login: root / rocky (documented, test image).
host identity       : ssh host keys + machine-id regenerated per box on first boot
supply chain        : every dnf repo verifies signatures (gpgcheck=1; repo_gpgcheck=1 for the container-toolkit repo)

hardening applied by 05
-----------------------
removed builder authorized_keys; sshd network-root lockdown; cleared host keys; machine-id reset to regenerate;
removed build-host shell history + leftover .run/tmp; installed validate.sh; verified proof-of-life.sh.
EOF

echo ""
echo "=== VENDABLE ARTIFACTS (no build required to consume) ==="
ls -lh "$ART" "$MANIFEST"
echo "  inner sha256: $INNER_SHA"
echo "  outer sha256: $OUTER_SHA"
echo ""
echo "Next: mint the release key, then sign with 06-sign-release.sh."
