# Esteira GitOps — demo-api

Pipeline completo: push no git → testes → build → imagem no GHCR → commit da
nova tag → Argo CD sincroniza o cluster.

## Fluxo

```
 push na main
      │
      ▼
┌─────────────┐   testes falham → para aqui
│   test      │   pytest + ruff
└──────┬──────┘
       ▼
┌─────────────┐
│   build     │   docker build → ghcr.io/<owner>/demo-api:<sha>
└──────┬──────┘   tag imutável (SHA), nunca 'latest' em deploy
       ▼
┌─────────────┐
│ update-     │   sed na tag do overlay + commit "[skip ci]"
│ manifest    │
└──────┬──────┘
       ▼
   (git)  ◄────────── Argo CD faz PULL a cada 3 min
       │
       ▼
┌─────────────┐
│  cluster    │   dev: auto-sync · prod: sync manual
└─────────────┘
```

**O CI nunca fala com o cluster.** Essa é a diferença do modelo pull-based:
não há credencial de cluster no GitHub, e o git é a única fonte de verdade.

## Estrutura

| Caminho | O quê |
|---|---|
| `app/` | FastAPI com `/health`, `/ready`, `/metrics`, `/work` |
| `k8s/base/` | Deployment, Service, PDB |
| `k8s/overlays/dev/` | 1 réplica, auto-sync |
| `k8s/overlays/prod/` | 2 réplicas, sync manual, CPU maior |
| `argocd/` | Instalação e Applications |
| `../.github/workflows/ci-cd.yaml` | O pipeline |

## Como subir

```bash
# 1. Argo CD (já instalado neste cluster)
bash argocd/install.sh

# 2. Publique o repo no GitHub, depois registre as Applications
bash bootstrap.sh

# 3. UI
#    https://192.168.172.130:30443   admin / veja o comando abaixo
```

## Demonstrações que valem numa entrevista

### Self-healing — o argumento mais forte do GitOps

```bash
kubectl -n demo-dev scale deployment demo-api --replicas=5
kubectl -n demo-dev get pods -w
# O Argo CD detecta a divergência e volta para o que está no git.
```

> *"Alteração manual em produção não sobrevive. O cluster converge para o git,
> sempre. Isso elimina drift de configuração."*

### Rollback por git

```bash
git revert HEAD && git push
# O Argo CD aplica a versão anterior sozinho.
```

> *"Rollback é `git revert` — auditável, com autor e motivo. Não existe
> 'quem foi que mexeu no cluster'."*

### Deploy sem downtime

```bash
kubectl -n demo-dev get pods -w   # numa aba
# noutra: faça um push e acompanhe o rolling update
```

`maxUnavailable: 0` garante que o pod novo só substitui o antigo depois de
ficar `Ready`. A `readinessProbe` é o que sustenta isso.

### Promoção dev → prod

```bash
# copie a tag validada em dev para o overlay de prod, commit e push
# depois sincronize prod manualmente (é uma decisão, não automação)
kubectl -n argocd patch app demo-api-prod --type merge \
  -p '{"operation":{"sync":{"revision":"main"}}}'
```

## Validado neste cluster

Executado de ponta a ponta, não apenas escrito:

| Verificação | Resultado |
|---|---|
| Pipeline completo (test → build → update-manifest) | ✅ 57s, verde |
| Bot commitou a nova tag | ✅ `deploy(dev): 7962b92 [skip ci]` |
| Argo CD sincronizou sozinho | ✅ `Synced` / `Healthy` |
| Imagem em execução | ✅ `ghcr.io/mateusjacomine/demo-api:7962b92` |
| App reporta a versão do commit | ✅ `{"version":"7962b92"}` |
| Métricas Prometheus | ✅ 131 linhas, com histograma para p95/p99 |
| **Self-healing** | ✅ escalei para 5 réplicas → **voltou para 1 em ~5s** |
| Testes da app | ✅ 8 passando |

### Um bug real que a esteira pegou

O primeiro deploy entrou em `CrashLoopBackOff`. Diagnóstico pelo log do
container: `AssertionError: A version must be provided for OpenAPI`.

**Causa raiz:** o Deployment injetava `APP_VERSION` via `fieldRef` do label
`app.kubernetes.io/version`, mas o Kustomize aplica esse label com
`includeSelectors: false` — ele não chega ao pod template. A variável chegava
**vazia**, e `os.getenv("APP_VERSION", "dev")` não protege: o default só age
quando a variável **não existe**, não quando existe vazia.

**Correção em duas camadas:** `os.getenv(...) or "dev"` na aplicação, e o valor
literal no manifesto atualizado pelo CI junto com a tag. Mais um teste de
regressão que roda em subprocesso.

> Vale contar essa história numa entrevista: é exatamente o tipo de bug que só
> aparece no cluster e se resolve lendo o log do container, não adivinhando.

## Decisões de projeto (esteja pronto para justificar)

| Decisão | Por quê |
|---|---|
| **Pull em vez de push** | Sem credencial de cluster no CI; funciona com cluster privado |
| **Tag por SHA, não `latest`** | `latest` é mutável: você não sabe o que está rodando nem consegue reverter |
| **`maxUnavailable: 1` no PDB** | `minAvailable: N` com N réplicas trava o drain para sempre |
| **prod sem auto-sync** | Promover é decisão humana; dev valida antes |
| **`startupProbe` separada** | Protege boot lento sem afrouxar a liveness em regime |
| **Sem limit de CPU** | Limit de CPU causa throttling; request já garante o scheduling |
| **`runAsNonRoot` + `readOnlyRootFilesystem`** | Baseline de segurança que auditoria cobra |
