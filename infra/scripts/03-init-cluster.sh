#!/usr/bin/env bash
# Inicializa o control-plane e instala o Calico. Roda em k8s-cp1 como root.
set -euo pipefail

CP_IP="${CP_IP:-192.168.172.11}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

echo "==> kubeadm init (advertise ${CP_IP}, podCIDR ${POD_CIDR})"
kubeadm init \
  --apiserver-advertise-address="${CP_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --node-name="$(hostname -s)" \
  --cri-socket=unix:///run/containerd/containerd.sock

echo "==> kubeconfig para root e para o usuario vagrant"
mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config
mkdir -p /home/vagrant/.kube && cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

export KUBECONFIG=/etc/kubernetes/admin.conf

echo "==> Instalando Calico (operator + custom resources)"
# Calico e nao Flannel: NetworkPolicy funcional e obrigatoria nos cenarios de rede
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml

# Ajusta o CIDR do Calico para bater com o do kubeadm
curl -sSL -o /tmp/calico-cr.yaml \
  https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/custom-resources.yaml
sed -i "s|cidr: 192.168.0.0/16|cidr: ${POD_CIDR}|" /tmp/calico-cr.yaml
kubectl create -f /tmp/calico-cr.yaml

echo "==> Aguardando os nodes ficarem Ready (ate 5 min)"
kubectl wait --for=condition=Ready node --all --timeout=300s || {
  echo "AVISO: nodes ainda nao Ready. Diagnostico:"
  kubectl get pods -A -o wide
  kubectl describe node "$(hostname -s)" | sed -n '/Conditions:/,/Addresses:/p'
}

echo "==> Gerando comando de join para os workers"
kubeadm token create --print-join-command | tee /root/join-command.sh
chmod +x /root/join-command.sh
cp /root/join-command.sh /home/vagrant/join-command.sh
chown vagrant:vagrant /home/vagrant/join-command.sh

echo "==> Cluster inicializado"
kubectl get nodes -o wide
kubectl get pods -A
