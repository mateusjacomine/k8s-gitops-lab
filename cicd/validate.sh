#!/usr/bin/env bash
# Valida a esteira localmente: testes da app + render dos overlays.
set -u
ROOT=/mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd

echo "=== TESTES DA APP ==="
bash "$ROOT/app/run-tests.sh" 2>&1 | tail -4

echo
echo "=== APP_VERSION POR OVERLAY ==="
for e in dev prod; do
  echo "-- $e --"
  kubectl kustomize "$ROOT/k8s/overlays/$e" | grep -A1 'name: APP_VERSION'
  kubectl kustomize "$ROOT/k8s/overlays/$e" | grep 'image:'
done

echo
echo "=== DRY-RUN NO SERVIDOR ==="
kubectl create ns demo-dev --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
kubectl kustomize "$ROOT/k8s/overlays/dev" | kubectl apply --dry-run=server -f - 2>&1 | head -5
