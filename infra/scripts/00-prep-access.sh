#!/usr/bin/env bash
# Instala chave SSH, habilita sudo NOPASSWD e define hostname em cada VM.
# Roda a partir do WSL. Idempotente.
set -u
PASS="${LAB_PASS:-vagrant}"
USER_="${LAB_USER:-vagrant}"
KEY=/root/.ssh/k8slab
PUB=$(cat "$KEY.pub")
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

for entry in "k8s-cp1:192.168.172.130" "k8s-w1:192.168.172.131" "k8s-w2:192.168.172.132"; do
  host="${entry%%:*}"; ip="${entry##*:}"
  echo "=== $host ($ip) ==="

  # 1) Chave publica + sudo NOPASSWD (unica etapa que usa senha)
  sshpass -p "$PASS" ssh $SSHOPTS "$USER_@$ip" "
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    grep -qF '$PUB' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUB' >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    echo '$PASS' | sudo -S sh -c \"echo '$USER_ ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-$USER_; chmod 440 /etc/sudoers.d/90-$USER_\" 2>/dev/null
  " 2>&1 | grep -v '^\[sudo\]' || true

  # 2) Daqui em diante: chave + sudo sem senha
  ssh -i "$KEY" $SSHOPTS "$USER_@$ip" "
    sudo hostnamectl set-hostname '$host'
    # /etc/hosts com os 3 nos: kubeadm e o kubelet resolvem nomes entre si
    sudo sed -i '/k8s-cp1\|k8s-w1\|k8s-w2/d' /etc/hosts
    sudo tee -a /etc/hosts >/dev/null <<'HOSTS'
192.168.172.130 k8s-cp1
192.168.172.131 k8s-w1
192.168.172.132 k8s-w2
HOSTS
    echo \"  hostname -> \$(hostname)\"
    echo \"  sudo     -> \$(sudo -n true 2>/dev/null && echo NOPASSWD || echo FALHOU)\"
  " 2>&1
done
