#!/bin/bash
# Finalize v2: write WiFi NM profile from netplan creds (password stays on box), re-arm one-time boot.
set -uo pipefail
R=/media/max/rocky-root
DEST="$R/etc/NetworkManager/system-connections/CapybaraCove.nmconnection"
echo "=== 1. write WiFi NM profile (creds read from netplan ON the box; not printed) ==="
sudo mkdir -p "$R/etc/NetworkManager/system-connections"
sudo python3 - "$DEST" <<'PY'
import glob,yaml,sys,os
dest=sys.argv[1]; ssid=psk=None
for f in sorted(glob.glob('/etc/netplan/*.yaml')+glob.glob('/etc/netplan/*.yml')):
    d=yaml.safe_load(open(f)) or {}
    for k,cfg in ((d.get('network',{}) or {}).get('wifis',{}) or {}).items():
        for name,apc in ((cfg or {}).get('access-points',{}) or {}).items():
            pw=((apc or {}).get('auth',{}) or {}).get('password') or (apc or {}).get('password')
            if pw: ssid,psk=name,pw; break
        if ssid: break
    if ssid: break
if not ssid: print("NO-CREDS-FOUND"); sys.exit(1)
open(dest,'w').write(f"""[connection]
id={ssid}
type=wifi
autoconnect=true
autoconnect-priority=999

[wifi]
mode=infrastructure
ssid={ssid}
cloned-mac-address=permanent

[wifi-security]
key-mgmt=wpa-psk
psk={psk}

[ipv4]
method=auto

[ipv6]
method=auto
""")
os.chmod(dest,0o600); print("WROTE ssid="+ssid)
PY
sudo chown root:root "$DEST"; sudo chmod 600 "$DEST"
echo "--- profile (psk redacted) ---"; sudo sed -E 's/(psk=).*/\1<REDACTED>/' "$DEST"
echo "=== 2. re-arm one-time boot into Rocky ==="
sudo grub-reboot "Rocky-10.2-6.18.34-GB10" && echo "ONE-TIME-ARMED" || { echo "grub-reboot failed; re-run update-grub"; sudo update-grub 2>&1 | tail -2; sudo grub-reboot "Rocky-10.2-6.18.34-GB10"; }
echo "=== 3. final stick state ==="
echo "nvidia resolves: $(sudo chroot "$R" modprobe -S 6.18.34 --dry-run --show-depends nvidia 2>&1 | tail -1)"
echo "wifi profile:    $(sudo test -f "$DEST" && echo present || echo MISSING)"
echo "wifi firmware:   $(sudo ls "$R"/lib/firmware/mediatek/mt7925/ 2>/dev/null | head -1)"
echo "gsp firmware:    $(sudo ls "$R"/lib/firmware/nvidia/610.43.02/ 2>/dev/null | grep gsp_ga10x)"
echo "autoload conf:   $(sudo cat "$R"/etc/modules-load.d/nvidia.conf 2>/dev/null | tr '\n' ' ')"
sync
echo "FINALIZE-DONE -- ready to reboot into v2"
