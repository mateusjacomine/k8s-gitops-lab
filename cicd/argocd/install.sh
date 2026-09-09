#!/usr/bin/env bash
# Instala o Argo CD no cluster e expoe a UI via NodePort.
set -u
VER="${ARGOCD_VERSION:-v2.13.2}"

echo "==> Namespace argocd"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "==> Instalando Argo CD ${VER}"
kubectl apply -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${VER}/manifests/install.yaml"

echo "==> Aguardando os pods (pode levar 3-5 min na primeira vez)"
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=600s || {
  echo "AVISO: nem todos ficaram prontos. Estado:"
  kubectl -n argocd get pods
}

echo "==> Expondo a UI via NodePort 30443"
kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"targetPort":8080,"nodePort":30443},{"name":"http","port":80,"targetPort":8080,"nodePort":30080}]}}'

echo
echo "==> Argo CD instalado"
kubectl -n argocd get pods
echo
echo "  UI:      https://192.168.172.130:30443   (aceite o certificado self-signed)"
echo "  usuario: admin"
echo -n "  senha:   "
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(secret ainda nao criado)"
echo
