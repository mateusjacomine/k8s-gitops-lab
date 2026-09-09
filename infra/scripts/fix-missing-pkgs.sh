#!/usr/bin/env bash
# Instala pacotes que o kubeadm exige e que a instalacao minimal nao traz.
# conntrack-tools: obrigatorio para o kube-proxy (preflight fatal sem ele)
# socat/ethtool: usados por port-forward e pelo kubelet
set -u
KEY=/root/.ssh/k8slab
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

pids=()
for ip in 192.168.172.130 192.168.172.131 192.168.172.132; do
  (
    ssh -i "$KEY" $SSHOPTS "vagrant@$ip" '
      sudo dnf install -y -q conntrack-tools socat ethtool iproute-tc \
        bind-utils tcpdump nmap-ncat jq sysstat >/dev/null 2>&1
      printf "%s: conntrack=%s socat=%s tc=%s\n" "$(hostname)" \
        "$(command -v conntrack >/dev/null && echo ok || echo FALTA)" \
        "$(command -v socat >/dev/null && echo ok || echo FALTA)" \
        "$(command -v tc >/dev/null && echo ok || echo FALTA)"
    '
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
