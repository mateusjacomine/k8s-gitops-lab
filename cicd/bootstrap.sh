#!/usr/bin/env bash
# Registra as Applications do Argo CD apontando para o SEU repositorio.
# Rode DEPOIS de publicar o repo no GitHub.
#
#   bash bootstrap.sh                      # usa mateusjacomine/k8s-gitops-lab
#   REPO_URL=https://github.com/x/y bash bootstrap.sh
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/mateusjacomine/k8s-gitops-lab.git}"

echo "==> Repositorio: $REPO_URL"

# Aplica as Applications com o repoURL correto
for env in dev prod; do
  sed "s|repoURL: .*|repoURL: ${REPO_URL}|" "$DIR/argocd/application-${env}.yaml" \
    | kubectl apply -f -
done

echo
echo "==> Applications registradas"
kubectl -n argocd get applications
echo
echo "  dev  -> auto-sync ligado (prune + selfHeal)"
echo "  prod -> sync manual: kubectl -n argocd patch app demo-api-prod --type merge \\"
echo "            -p '{\"operation\":{\"sync\":{\"revision\":\"main\"}}}'"
echo
echo "  UI: https://192.168.172.130:30443  (admin / veja a senha abaixo)"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null && echo
