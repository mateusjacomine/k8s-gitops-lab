#!/usr/bin/env bash
# Confere os pre-requisitos criticos antes do kubeadm init.
set -u
KEY=/root/.ssh/k8slab
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

for ip in 192.168.172.130 192.168.172.131 192.168.172.132; do
  echo "=============== $ip ==============="
  ssh -i "$KEY" $SSHOPTS "vagrant@$ip" '
    echo "  host:       $(hostname)"
    echo "  swap:       $(swapon --show --noheadings 2>/dev/null | wc -l) (esperado 0)"
    echo "  selinux:    $(getenforce)"
    echo "  firewalld:  $(systemctl is-active firewalld 2>/dev/null || echo inactive)"
    echo "  br_netfilter: $(lsmod | grep -c br_netfilter)"
    echo "  ip_forward: $(sysctl -n net.ipv4.ip_forward)"
    echo "  bridge-nf:  $(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo AUSENTE)"
    echo "  containerd: $(systemctl is-active containerd)"
    echo "  kubelet:    $(systemctl is-active kubelet) (activating e normal antes do init)"
    # containerd 2.x mudou o caminho da opcao; procura em qualquer versao
    echo "  SystemdCgroup: $(grep -c "SystemdCgroup = true" /etc/containerd/config.toml)"
    echo "  runtime:    $(sudo crictl info 2>/dev/null | grep -o "\"runtimeType\": \"[^\"]*\"" | head -1 || echo "crictl falhou")"
  ' 2>&1
done
