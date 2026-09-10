#!/usr/bin/env bash
# Instala Prometheus + Grafana (kube-prometheus-stack) dimensionado para o lab.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_VERSION="${CHART_VERSION:-66.3.1}"

echo "==> Adicionando o repositorio Helm"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo "==> Instalando kube-prometheus-stack ${CHART_VERSION}"
echo "    (baixa ~10 imagens; 5-8 min na primeira vez)"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "${CHART_VERSION}" \
  --namespace monitoring --create-namespace \
  --values "$DIR/values-prometheus.yaml" \
  --timeout 15m \
  --wait

echo
echo "==> Componentes"
kubectl -n monitoring get pods

echo
echo "==> Acesso"
echo "  Grafana:    http://192.168.172.130:30300   (admin / admin)"
echo "  Prometheus: kubectl -n monitoring port-forward --address 0.0.0.0 svc/monitoring-kube-prometheus-prometheus 9090:9090"
