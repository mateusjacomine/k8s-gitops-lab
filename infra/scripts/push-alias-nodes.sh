#!/usr/bin/env bash
# Instala os aliases nos 3 nos do cluster (usuario vagrant e root).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/setup-alias-wsl.sh"
KEY=/root/.ssh/k8slab
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR"

for ip in 192.168.172.130 192.168.172.131 192.168.172.132; do
  echo "=== $ip ==="
  sed 's/\r$//' "$SRC" | ssh -i "$KEY" $SSHOPTS "vagrant@$ip" \
    'cat > /tmp/al.sh && bash /tmp/al.sh >/dev/null && sudo TARGET_RC=/root/.bashrc bash /tmp/al.sh >/dev/null && echo "  aliases instalados para vagrant e root"' 2>&1 | tail -2
done
