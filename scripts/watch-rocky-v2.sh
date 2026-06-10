#!/bin/bash
# Wait for Rocky-v2 to come up on WiFi, then auto-run the Tier 1+2 proof (uname / os / nvidia-smi).
SSHK="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o BatchMode=yes -i $HOME/.ssh/id_ed25519"
MAC="58:02:05:e2:ef:c8"
echo "waiting for Rocky on WiFi (root@.123 first, then sweep for MAC $MAC)..."
ROCKYIP=""
for i in $(seq 1 32); do
  K=$(timeout 8 ssh $SSHK root@192.168.1.123 'uname -r' 2>/dev/null)
  if echo "$K" | grep -q 6.18; then ROCKYIP=192.168.1.123; break; fi
  for n in $(seq 1 254); do ping -c1 -W1 192.168.1.$n >/dev/null 2>&1 & done; wait
  IP=$(ip neigh | grep -i "$MAC" | grep -oE "192\.168\.1\.[0-9]+" | head -1)
  if [ -n "$IP" ] && [ "$IP" != "192.168.1.123" ]; then
    K=$(timeout 8 ssh $SSHK root@$IP 'uname -r' 2>/dev/null)
    echo "$K" | grep -q 6.18 && { ROCKYIP=$IP; break; }
  fi
  echo "poll $i: not up (.123 uname='$K', MAC at '${IP:-none}')"; sleep 14
done
[ -z "$ROCKYIP" ] && { echo "ROCKY-NOT-REACHABLE after ~7.5 min — check the monitor"; exit 1; }
echo ">>> ROCKY-V2 UP at $ROCKYIP <<<"
echo "================= TIER 1 + TIER 2 PROOF ================="
ssh $SSHK root@$ROCKYIP 'set +e
echo "### uname ###"; uname -r
echo "### os ###"; grep PRETTY_NAME /etc/os-release
echo "### network ###"; ip -br a | grep -v "^lo"
echo "### load nvidia (autoload may have already) ###"; modprobe nvidia 2>&1; sleep 3
echo "### lsmod ###"; lsmod | grep nvidia
echo "### NVIDIA-SMI ###"; nvidia-smi 2>&1 | head -25
echo "### dmesg nvidia/gsp/nvrm ###"; dmesg 2>/dev/null | grep -iE "nvidia|gsp|nvrm|NVRM" | tail -18'
echo "================= WATCHER-DONE ip=$ROCKYIP ================="
