#!/usr/bin/env bash
# Junta w1 e w2 ao cluster e exporta o kubeconfig para o WSL.
set -u
KEY=/root/.ssh/k8slab
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
CP=192.168.172.130

echo "==> Obtendo comando de join do control-plane"
JOIN=$(ssh -i "$KEY" $SSHOPTS "vagrant@$CP" 'sudo kubeadm token create --print-join-command' 2>/dev/null)
[ -n "$JOIN" ] || { echo "ERRO: nao consegui gerar o join command"; exit 1; }
echo "    $JOIN"

for ip in 192.168.172.131 192.168.172.132; do
  (
    echo "==> Juntando $ip"
    ssh -i "$KEY" $SSHOPTS "vagrant@$ip" "sudo $JOIN" 2>&1 | tail -4
  ) &
done
wait

echo
echo "==> Exportando kubeconfig para o WSL"
mkdir -p /root/.kube
ssh -i "$KEY" $SSHOPTS "vagrant@$CP" 'sudo cat /etc/kubernetes/admin.conf' > /root/.kube/config 2>/dev/null
chmod 600 /root/.kube/config
# O admin.conf aponta para o IP interno; ja e alcancavel do WSL via NAT
kubectl config current-context 2>/dev/null || true

echo
echo "==> Estado do cluster"
kubectl get nodes -o wide 2>&1
