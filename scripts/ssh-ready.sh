#!/bin/bash
# Ensure Rocky stick is SSH-reachable: openssh-server installed+enabled, root login allowed, laptop key added.
set -uo pipefail
R=/media/max/rocky-root
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNy5ftE4B2UOb/c5o2w/EgZutd3GwgtyKKHiTt2gH3g spevack-gemini-2026-02-17"
echo "=== openssh-server present in rootfs? ==="
if sudo test -f "$R/usr/sbin/sshd"; then
  echo "sshd: present"
else
  echo "sshd MISSING -> installing via chroot dnf"
  sudo cp /etc/resolv.conf "$R/etc/resolv.conf" 2>/dev/null || true
  for d in proc sys dev; do sudo mount --bind /$d "$R/$d" 2>/dev/null; done
  sudo chroot "$R" dnf -y install openssh-server 2>&1 | tail -3
  for d in dev sys proc; do sudo umount "$R/$d" 2>/dev/null; done
fi
echo "=== enable sshd at boot ==="
sudo chroot "$R" systemctl enable sshd 2>/dev/null \
  || sudo ln -sf /usr/lib/systemd/system/sshd.service "$R/etc/systemd/system/multi-user.target.wants/sshd.service"
echo "=== allow root login + password auth ==="
sudo mkdir -p "$R/etc/ssh/sshd_config.d"
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' | sudo tee "$R/etc/ssh/sshd_config.d/99-rocky-gb10.conf" >/dev/null
echo "=== add laptop pubkey to root authorized_keys ==="
sudo mkdir -p "$R/root/.ssh"; sudo chmod 700 "$R/root/.ssh"
echo "$PUBKEY" | sudo tee -a "$R/root/.ssh/authorized_keys" >/dev/null
sudo chmod 600 "$R/root/.ssh/authorized_keys"; sudo chown -R 0:0 "$R/root/.ssh"
echo "--- verify ---"
echo "sshd enabled: $(sudo chroot "$R" systemctl is-enabled sshd 2>/dev/null || echo '(symlinked)')"
echo "authorized_keys lines: $(sudo wc -l < "$R/root/.ssh/authorized_keys")"
echo "sshd drop-in: $(sudo cat "$R/etc/ssh/sshd_config.d/99-rocky-gb10.conf" | tr '\n' ' ')"
sync
echo "SSH-READY-DONE"
