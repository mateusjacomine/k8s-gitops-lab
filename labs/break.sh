#!/usr/bin/env bash
# Quebra o cluster de proposito, para treinar diagnostico.
# Rodar NO control-plane (k8s-cp1) ou do WSL com KUBECONFIG apontado.
#
#   ./break.sh kubelet-down      # node NotReady
#   ./break.sh coredns-down      # DNS quebrado
#   ./break.sh disk-pressure     # DiskPressure em w1
#   ./break.sh netpol            # default-deny
#   ./break.sh pods              # pods quebrados variados
#   ./break.sh fix <cenario>     # restaura
set -u

KEY=${KEY:-/root/.ssh/k8slab}
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR"
W1=192.168.172.131
LABS="$(cd "$(dirname "$0")" && pwd)"

remote() { ssh -i "$KEY" $SSHOPTS "vagrant@$1" "${@:2}"; }

case "${1:-}" in
  kubelet-down)
    echo "==> Parando kubelet em k8s-w1. Observe: kubectl get nodes -w"
    echo "    (~40s ate NotReady: node-monitor-grace-period)"
    remote $W1 'sudo systemctl stop kubelet'
    echo "    Pergunte-se: os PODS do node pararam? (nao — o containerd segue vivo)"
    ;;
  fix-kubelet-down)
    remote $W1 'sudo systemctl start kubelet'
    echo "==> kubelet religado; node volta a Ready em ~20s"
    ;;

  coredns-down)
    echo "==> Escalando CoreDNS para 0. DNS do cluster para de resolver."
    kubectl -n kube-system scale deployment coredns --replicas=0
    echo "    Teste: kubectl run t --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default"
    ;;
  fix-coredns-down)
    kubectl -n kube-system scale deployment coredns --replicas=2
    ;;

  disk-pressure)
    echo "==> Enchendo /var em k8s-w1 para disparar DiskPressure"
    remote $W1 'sudo fallocate -l 13G /var/enchendo.img; df -h /var | tail -1'
    echo "    Observe: kubectl describe node k8s-w1 | grep -A6 Conditions"
    ;;
  fix-disk-pressure)
    remote $W1 'sudo rm -f /var/enchendo.img; df -h /var | tail -1'
    ;;

  netpol)
    echo "==> Aplicando default-deny em backend"
    kubectl apply -f "$LABS/03-network/netpol-deny.yaml"
    echo "    Teste do frontend:"
    echo "    kubectl -n frontend exec client -- curl -m3 api.backend.svc.cluster.local"
    ;;
  fix-netpol)
    kubectl -n backend delete networkpolicy default-deny-ingress allow-frontend-to-api --ignore-not-found
    ;;

  pods)
    kubectl apply -f "$LABS/01-pods/broken-pods.yaml"
    echo "==> Pods quebrados aplicados. kubectl -n lab-pods get pods -w"
    ;;
  fix-pods)
    kubectl delete -f "$LABS/01-pods/broken-pods.yaml" --ignore-not-found
    ;;

  status)
    echo "=== NODES ==="; kubectl get nodes -o wide
    echo; echo "=== PODS COM PROBLEMA ==="
    kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | head -20
    echo; echo "=== EVENTOS RECENTES ==="
    kubectl get events -A --sort-by='.metadata.creationTimestamp' 2>/dev/null | tail -10
    ;;

  fix)
    for c in kubelet-down coredns-down disk-pressure netpol pods; do
      "$0" "fix-$c" 2>/dev/null || true
    done
    echo "==> Tudo restaurado"
    ;;

  *)
    grep '^#   ' "$0" | sed 's/^#   //'
    ;;
esac
