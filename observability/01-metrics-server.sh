#!/usr/bin/env bash
# Instala o metrics-server, que habilita `kubectl top nodes/pods`.
# Leve (~50Mi) e pre-requisito para HPA.
set -u

echo "==> Instalando metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

echo "==> Ajustando para o lab (kubelet com certificado self-signed)"
# Em cluster kubeadm de lab, o certificado do kubelet nao e assinado por uma CA
# que o metrics-server reconheca. Sem esta flag ele fica CrashLoop com erro TLS.
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

echo "==> Aguardando ficar disponivel"
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

echo
echo "==> Teste (pode levar ~30s ate a primeira coleta)"
sleep 30
kubectl top nodes
