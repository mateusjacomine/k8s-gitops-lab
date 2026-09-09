#!/usr/bin/env bash
# Instala kubectl e o kubeconfig do cluster na distro WSL atual.
# Uso:  wsl -d <distro> -u root -- bash <caminho>/setup-kubectl-wsl.sh
set -u

ARCH=amd64
BIN=/usr/local/bin/kubectl

if ! command -v kubectl >/dev/null 2>&1; then
  echo "==> Instalando kubectl"
  VER=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLo "$BIN" "https://dl.k8s.io/release/${VER}/bin/linux/${ARCH}/kubectl"
  chmod +x "$BIN"
  echo "    kubectl ${VER} instalado"
else
  echo "==> kubectl ja presente: $(command -v kubectl)"
fi

echo "==> Buscando kubeconfig do control-plane"
mkdir -p /root/.kube

# Usa a chave do lab se existir; senao cai para senha
KEY=/root/.ssh/k8slab
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

if [ -f "$KEY" ]; then
  ssh -i "$KEY" $SSHOPTS vagrant@192.168.172.130 'sudo cat /etc/kubernetes/admin.conf' > /root/.kube/config 2>/dev/null
else
  command -v sshpass >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq sshpass >/dev/null 2>&1; }
  sshpass -p vagrant ssh $SSHOPTS vagrant@192.168.172.130 \
    'echo vagrant | sudo -S cat /etc/kubernetes/admin.conf' > /root/.kube/config 2>/dev/null
fi

if [ ! -s /root/.kube/config ]; then
  echo "ERRO: nao consegui obter o kubeconfig. O control-plane esta ligado?"
  exit 1
fi
chmod 600 /root/.kube/config

echo "==> Teste"
kubectl get nodes -o wide
