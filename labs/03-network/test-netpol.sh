#!/usr/bin/env bash
# Roteiro completo de NetworkPolicy: prova que funciona -> nega -> libera.
# Execute passo a passo na entrevista, explicando cada etapa.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

hr() { printf '%s\n' "-------------------------------------------"; }

echo "=== PASSO 1: conectividade SEM policy (baseline) ==="
kubectl -n backend delete networkpolicy --all >/dev/null 2>&1
sleep 5
kubectl -n frontend exec client -- curl -s -o /dev/null -w 'frontend -> api: %{http_code}\n' -m5 http://api.backend.svc.cluster.local || echo 'frontend: sem resposta'
kubectl -n backend  exec client-interno -- curl -s -o /dev/null -w 'interno  -> api: %{http_code}\n' -m5 http://api.backend.svc.cluster.local || echo 'interno: sem resposta'
hr

echo "=== PASSO 2: default-deny-ingress (podSelector {} = TODOS os pods) ==="
kubectl apply -f "$DIR/netpol-deny.yaml" >/dev/null
# mantem so a policy de deny para este passo
kubectl -n backend delete networkpolicy allow-frontend-to-api --ignore-not-found >/dev/null 2>&1
echo "aguardando o Calico programar as regras..."
sleep 8
kubectl -n frontend exec client -- curl -s -o /dev/null -w 'frontend -> api: %{http_code}\n' -m5 http://api.backend.svc.cluster.local || echo 'frontend -> api: BLOQUEADO (esperado)'
kubectl -n backend  exec client-interno -- curl -s -o /dev/null -w 'interno  -> api: %{http_code}\n' -m5 http://api.backend.svc.cluster.local || echo 'interno  -> api: BLOQUEADO (esperado - deny vale ate dentro do namespace)'
hr

echo "=== PASSO 3: liberando SOMENTE o namespace frontend ==="
kubectl apply -f "$DIR/netpol-deny.yaml" >/dev/null
sleep 8
kubectl -n frontend exec client -- curl -s -o /dev/null -w 'frontend -> api: %{http_code} (esperado 200)\n' -m5 http://api.backend.svc.cluster.local || echo 'frontend: ainda bloqueado'
kubectl -n backend  exec client-interno -- curl -s -o /dev/null -w 'interno  -> api: %{http_code}\n' -m5 http://api.backend.svc.cluster.local || echo 'interno  -> api: BLOQUEADO (esperado - so frontend foi liberado)'
hr

echo "=== Policies ativas ==="
kubectl -n backend get networkpolicy
echo
echo "Para limpar: kubectl -n backend delete networkpolicy --all"
