#!/usr/bin/env bash
# Reaplica os aliases nesta distro WSL e nos 3 nos do cluster.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/setup-alias-wsl.sh"

echo "=== distro local ($(. /etc/os-release; echo "$NAME")) ==="
sed -i 's/\r$//' "$SRC"
bash "$SRC" >/dev/null
grep -E "alias (kdp|kgpw)=" "$HOME/.bashrc" || echo "  AVISO: aliases novos nao encontrados"

KEY=/root/.ssh/k8slab
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR"
[ -f "$KEY" ] || { echo "sem chave $KEY - pulando os nos"; exit 0; }

for ip in 192.168.172.130 192.168.172.131 192.168.172.132; do
  echo "=== $ip ==="
  sed 's/\r$//' "$SRC" | ssh -i "$KEY" $SSHOPTS "vagrant@$ip" \
    'cat > /tmp/al.sh && bash /tmp/al.sh >/dev/null && sudo TARGET_RC=/root/.bashrc bash /tmp/al.sh >/dev/null && grep -cE "alias (kdp|kgpw)=" ~/.bashrc | xargs -I{} echo "  {} aliases novos instalados"' 2>&1 | tail -1
done
