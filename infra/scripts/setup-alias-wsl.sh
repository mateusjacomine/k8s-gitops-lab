#!/usr/bin/env bash
# Configura alias 'k' + autocomplete para kubectl no bash da distro atual.
# Idempotente: pode rodar varias vezes.
set -u

RC="${TARGET_RC:-$HOME/.bashrc}"
MARK="# === k8s lab aliases ==="

# Remove bloco anterior, se houver, para nao duplicar
if grep -qF "$MARK" "$RC" 2>/dev/null; then
  sed -i "/$MARK/,/# === fim k8s lab ===/d" "$RC"
fi

cat >> "$RC" <<'EOF'
# === k8s lab aliases ===
alias k=kubectl

# Autocomplete do kubectl e, em seguida, o mesmo completion para 'k'.
if command -v kubectl >/dev/null 2>&1; then
  source <(kubectl completion bash)
  complete -o default -F __start_kubectl k
fi

# Atalhos usados com mais frequencia em troubleshooting
alias kg='kubectl get'
alias kd='kubectl describe'
# describe pod: o uso dominante em troubleshooting (kd exige o tipo do recurso)
alias kdp='kubectl describe pod'
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'
# acompanha mudancas de estado ao vivo (Ctrl+C para sair)
alias kgpw='kubectl get pods -w'
alias kgn='kubectl get nodes -o wide'
alias kl='kubectl logs'
alias klp='kubectl logs --previous'
alias kaf='kubectl apply -f'
alias kdel='kubectl delete'
alias kex='kubectl exec -it'

# Eventos ordenados por tempo (eventos caducam em ~1h)
alias kev='kubectl get events -A --sort-by=.metadata.creationTimestamp'
# Pods que nao estao Running
alias kbad='kubectl get pods -A --field-selector=status.phase!=Running'

# Troca de namespace rapida:  kns lab-pods
kns() { kubectl config set-context --current --namespace="${1:-default}"; }
# === fim k8s lab ===
EOF

echo "alias adicionados em $RC"
grep -c 'alias k' "$RC"
