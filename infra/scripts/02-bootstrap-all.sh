#!/usr/bin/env bash
# Roda bootstrap-node.sh nos 3 nos em paralelo. A partir do WSL.
set -u
KEY=/root/.ssh/k8slab
USER_="${LAB_USER:-vagrant}"
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
SRC="$(dirname "$0")/bootstrap-node.sh"
LOGDIR=/tmp/k8slab-logs
mkdir -p "$LOGDIR"

pids=()
for ip in 192.168.172.130 192.168.172.131 192.168.172.132; do
  (
    sed 's/\r$//' "$SRC" | ssh -i "$KEY" $SSHOPTS "$USER_@$ip" \
      'cat > /tmp/bootstrap.sh && sudo bash /tmp/bootstrap.sh' \
      > "$LOGDIR/$ip.log" 2>&1
    echo "$? $ip" > "$LOGDIR/$ip.rc"
  ) &
  pids+=($!)
  echo "iniciado bootstrap em $ip (log: $LOGDIR/$ip.log)"
done

echo "aguardando os 3 nos (5-8 min: baixa containerd + kubeadm)..."
for p in "${pids[@]}"; do wait "$p"; done

echo
for ip in 192.168.172.130 192.168.172.131 192.168.172.132; do
  rc=$(cut -d' ' -f1 "$LOGDIR/$ip.rc" 2>/dev/null || echo '?')
  if [ "$rc" = "0" ]; then
    echo "=== $ip: OK ==="
    tail -3 "$LOGDIR/$ip.log"
  else
    echo "=== $ip: FALHOU (rc=$rc) ==="
    tail -15 "$LOGDIR/$ip.log"
  fi
done
