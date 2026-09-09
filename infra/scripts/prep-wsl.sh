#!/usr/bin/env bash
# Prepara o WSL como estacao de controle do lab (SSH automatizado + kubectl).
set -u
apt-get install -y -qq sshpass >/dev/null 2>&1

echo "sshpass: $(command -v sshpass || echo AUSENTE)"
echo "ssh:     $(command -v ssh || echo AUSENTE)"
echo "kubectl: $(command -v kubectl || echo 'ausente (instalo depois)')"

# Chave dedicada ao lab, sem passphrase, para automacao
KEY=/root/.ssh/k8slab
if [ ! -f "$KEY" ]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  ssh-keygen -t ed25519 -N '' -f "$KEY" -C 'k8s-lab' >/dev/null 2>&1
  echo "chave criada: $KEY"
else
  echo "chave ja existe: $KEY"
fi
echo "--- chave publica ---"
cat "$KEY.pub"
