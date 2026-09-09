# Esteira CI/CD GitOps — Documentação Técnica

**Projeto:** `k8s-gitops-lab`
**Repositório:** https://github.com/mateusjacomine/k8s-gitops-lab
**Autor:** Mateus Jacomine
**Data:** Setembro de 2026
**Status:** Operacional, validado end-to-end

---

## Sumário

1. [Visão geral](#1-visão-geral)
2. [Arquitetura](#2-arquitetura)
3. [Inventário do ambiente](#3-inventário-do-ambiente)
4. [Decisões de arquitetura e justificativas](#4-decisões-de-arquitetura-e-justificativas)
5. [Implementação — Aplicação](#5-implementação--aplicação)
6. [Implementação — Containerização](#6-implementação--containerização)
7. [Implementação — Manifestos Kubernetes](#7-implementação--manifestos-kubernetes)
8. [Implementação — Gestão de configuração (Kustomize)](#8-implementação--gestão-de-configuração-kustomize)
9. [Implementação — Continuous Integration](#9-implementação--continuous-integration)
10. [Implementação — Continuous Delivery (Argo CD)](#10-implementação--continuous-delivery-argo-cd)
11. [Procedimento de instalação completo](#11-procedimento-de-instalação-completo)
12. [Validação e evidências](#12-validação-e-evidências)
13. [Incidente: análise de causa raiz](#13-incidente-análise-de-causa-raiz)
14. [Operação](#14-operação)
15. [Segurança](#15-segurança)
16. [Limitações conhecidas e roadmap](#16-limitações-conhecidas-e-roadmap)
17. [Referência de comandos](#17-referência-de-comandos)

---

## 1. Visão geral

### 1.1 Objetivo

Implementar uma esteira de entrega contínua sobre Kubernetes seguindo o modelo
**GitOps pull-based**, na qual o repositório Git é a única fonte de verdade do
estado desejado do cluster, e a reconciliação é executada por um agente residente
no próprio cluster.

### 1.2 Escopo entregue

| Componente | Tecnologia | Estado |
|---|---|---|
| Aplicação instrumentada | FastAPI + prometheus-client | ✅ 8 testes |
| Containerização | Docker multi-stage, non-root | ✅ |
| Orquestração | Kubernetes 1.31.14 | ✅ 3 nós |
| Gestão de configuração | Kustomize (base + 2 overlays) | ✅ |
| Continuous Integration | GitHub Actions | ✅ 3 jobs |
| Registry | GitHub Container Registry | ✅ público |
| Continuous Delivery | Argo CD 2.13.2 | ✅ 2 Applications |
| Rede/NetworkPolicy | Calico 3.28.2 | ✅ |

### 1.3 Métricas da implementação

| Indicador | Valor medido |
|---|---|
| Tempo total do pipeline | **57 s** (test → build → update-manifest) |
| Tempo de reconciliação (self-heal) | **~5 s** |
| Cobertura de testes automatizados | 8 casos, incluindo 1 de regressão |
| Downtime durante deploy | **0** (`maxUnavailable: 0`) |
| Credenciais de cluster no CI | **Nenhuma** (modelo pull) |

---

## 2. Arquitetura

### 2.1 Fluxo de entrega

```
┌──────────────┐
│ Desenvolvedor│
└──────┬───────┘
       │ git push (origin/main)
       ▼
┌─────────────────────────────────────────────────────────┐
│ GITHUB — repositório k8s-gitops-lab                     │
│ Fonte de verdade do estado desejado                     │
└──────┬──────────────────────────────────────────────────┘
       │ webhook
       ▼
┌─────────────────────────────────────────────────────────┐
│ GITHUB ACTIONS — .github/workflows/ci-cd.yaml           │
│                                                         │
│  job: test              pytest + ruff                   │
│         │ needs                                         │
│         ▼                                               │
│  job: build             docker buildx → GHCR            │
│         │               tag = git short SHA             │
│         │ needs                                         │
│         ▼                                               │
│  job: update-manifest   sed newTag + git commit         │
└──────┬──────────────────────────────────────────────────┘
       │ commit "deploy(dev): <sha> [skip ci]"
       ▼
┌─────────────────────────────────────────────────────────┐
│ GITHUB — manifesto atualizado                           │
└──────┬──────────────────────────────────────────────────┘
       │
       │  ◄── PULL (polling 3 min ou webhook)
       │
┌──────┴──────────────────────────────────────────────────┐
│ CLUSTER KUBERNETES (192.168.172.0/24)                   │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │ namespace: argocd                                 │  │
│  │  application-controller — reconciliação           │  │
│  │  repo-server           — renderiza Kustomize      │  │
│  │  server                — API e UI (NodePort 30443)│  │
│  └────────────────┬──────────────────────────────────┘  │
│                   │ apply                               │
│         ┌─────────┴─────────┐                           │
│         ▼                   ▼                           │
│  ┌────────────┐      ┌────────────┐                     │
│  │ demo-dev   │      │ demo-prod  │                     │
│  │ auto-sync  │      │ sync manual│                     │
│  └────────────┘      └────────────┘                     │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Fronteira de segurança

O limite arquitetural determinante: **o pipeline de CI não possui credencial de
acesso ao cluster**. A comunicação é unidirecional — o CI escreve no Git, o
cluster lê do Git.

Consequências diretas:

- Comprometimento do GitHub Actions não implica comprometimento do cluster
- O cluster pode residir em rede privada sem ingress público
- A superfície de ataque do pipeline se restringe ao repositório e ao registry

### 2.3 Estrutura do repositório

```
k8s-gitops-lab/
├── .github/workflows/
│   └── ci-cd.yaml                 # pipeline: 124 linhas, 3 jobs
├── cicd/
│   ├── app/
│   │   ├── main.py                # aplicação: 120 linhas
│   │   ├── test_main.py           # testes: 87 linhas, 8 casos
│   │   ├── requirements.txt       # dependências fixadas
│   │   ├── Dockerfile             # multi-stage, non-root
│   │   └── .dockerignore
│   ├── k8s/
│   │   ├── base/                  # manifestos comuns
│   │   │   ├── deployment.yaml    # 82 linhas
│   │   │   ├── service.yaml
│   │   │   ├── pdb.yaml
│   │   │   └── kustomization.yaml
│   │   └── overlays/
│   │       ├── dev/               # 1 réplica, auto-sync
│   │       └── prod/              # 2 réplicas, sync manual
│   ├── argocd/
│   │   ├── install.sh
│   │   ├── application-dev.yaml
│   │   └── application-prod.yaml
│   ├── bootstrap.sh               # registra as Applications
│   └── validate.sh                # validação local pré-commit
```

---

## 3. Inventário do ambiente

### 3.1 Infraestrutura

| Host | IP | Função | Recursos |
|---|---|---|---|
| `k8s-cp1` | 192.168.172.130 | control-plane | 2 vCPU / 2.6 GB |
| `k8s-w1` | 192.168.172.131 | worker | 2 vCPU / 2.6 GB |
| `k8s-w2` | 192.168.172.132 | worker | 2 vCPU / 2.6 GB |

Hypervisor: VMware Workstation Pro 17.5.2 · Rede: NAT (vmnet8) `192.168.172.0/24`

### 3.2 Stack de software

| Camada | Componente | Versão |
|---|---|---|
| Sistema operacional | Rocky Linux | 9.8 (Blue Onyx) |
| Kernel | Linux | 5.14.0-687.10.1.el9_8 |
| Container runtime | containerd | 2.3.4 |
| Orquestrador | Kubernetes (kubeadm) | v1.31.14 |
| CNI | Calico | v3.28.2 |
| GitOps | Argo CD | v2.13.2 |
| Cliente | kubectl | v1.33.3 |

> **Nota sobre version skew:** o `kubectl` v1.33.3 opera sobre um cluster
> v1.31.14. A política de skew do Kubernetes admite o cliente até uma minor
> acima do servidor; aqui há duas de diferença, o que funciona para operações
> comuns mas pode divergir em recursos novos. Em produção, alinhar as versões.

### 3.3 Namespaces

| Namespace | Propósito | Política de sync |
|---|---|---|
| `argocd` | Plano de controle GitOps | — |
| `demo-dev` | Ambiente de desenvolvimento | Automated + prune + selfHeal |
| `demo-prod` | Ambiente de produção | Manual |
| `calico-system` | CNI | — |

---

## 4. Decisões de arquitetura e justificativas

### ADR-01 · Modelo pull (GitOps) em vez de push

**Contexto:** o pipeline precisa aplicar alterações no cluster.

**Alternativas avaliadas:**

| Opção | Análise |
|---|---|
| Push — CI executa `kubectl apply` | Exige kubeconfig como secret no CI; cluster precisa de endpoint alcançável pelo runner; sem detecção de drift |
| **Pull — agente no cluster (escolhida)** | Nenhuma credencial de cluster fora do cluster; funciona com cluster privado; drift detectado e corrigido |

**Decisão:** Argo CD em modelo pull.

**Consequências:** Adiciona um componente a operar dentro do cluster e um passo
de commit no fluxo. Em contrapartida, elimina a classe inteira de riscos ligada
a credenciais de cluster em sistemas externos.

---

### ADR-02 · Tag imutável (git SHA) em vez de `latest`

**Decisão:** toda imagem é publicada com o short SHA do commit
(`ghcr.io/mateusjacomine/demo-api:7962b92`). A tag `latest` é publicada apenas
por conveniência e **nunca referenciada em manifesto de deploy**.

**Justificativa:**

| Critério | `latest` | SHA |
|---|---|---|
| Rastreabilidade | Indeterminada | Commit exato |
| Rollback | Impossível (tag sobrescrita) | Alterar referência |
| Idempotência entre réplicas | Não garantida | Garantida |
| Auditoria | Inviável | Completa |

---

### ADR-03 · `maxUnavailable` em vez de `minAvailable` no PDB

**Decisão:** `maxUnavailable: 1`.

**Justificativa:** `minAvailable: N` com exatamente N réplicas produz
`ALLOWED DISRUPTIONS: 0`, bloqueando `kubectl drain` indefinidamente — falha
operacional recorrente durante manutenção de nós. `maxUnavailable` escala com o
número de réplicas e preserva a capacidade de drenar.

---

### ADR-04 · Produção sem sincronização automática

**Decisão:** `demo-api-prod` sem bloco `syncPolicy.automated`.

**Justificativa:** promoção para produção é decisão de negócio, não consequência
automática de um merge. O estado `OutOfSync` em produção é o comportamento
esperado — indica que há uma versão validada em dev aguardando aprovação.

---

### ADR-05 · Ausência de limite de CPU

**Decisão:** definir `requests.cpu` sem `limits.cpu`; definir `limits.memory`.

**Justificativa:** CPU é recurso compressível — o limite provoca throttling via
CFS quota (`container_cpu_cfs_throttled_seconds_total`), degradando latência sem
sinalizar erro. O `request` já assegura o scheduling. Memória, por ser
incompressível, mantém limite para evitar que um vazamento comprometa o nó.

---

### ADR-06 · Três probes distintas

**Decisão:** `startupProbe` + `readinessProbe` + `livenessProbe`.

| Probe | Endpoint | Efeito da falha |
|---|---|---|
| startup | `/health` | Suspende as demais; até 60 s de tolerância |
| readiness | `/ready` | Remove dos Endpoints (não reinicia) |
| liveness | `/health` | Reinicia o container |

**Justificativa:** sem `startupProbe`, o `failureThreshold` da liveness precisa
acomodar o pior caso de inicialização, retardando a detecção de travamentos em
regime. Separá-las permite tolerância alta no boot e baixa em operação.

---

## 5. Implementação — Aplicação

📄 `cicd/app/main.py` — 120 linhas

### 5.1 Endpoints

| Método | Rota | Função |
|---|---|---|
| GET | `/` | Metadados: versão e uptime |
| GET | `/health` | Liveness — processo responsivo |
| GET | `/ready` | Readiness — 503 até concluir a inicialização |
| GET | `/work` | Carga sintética para exercitar percentis |
| GET | `/metrics` | Exposição Prometheus |

### 5.2 Instrumentação

```python
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Latencia das requisicoes HTTP",
    ["method", "endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total de requisicoes HTTP",
    ["method", "endpoint", "status"],
)
APP_INFO = Gauge("app_info", "Metadados da aplicacao", ["version"])
READY = Gauge("app_ready", "1 quando a aplicacao esta pronta")
```

**Controle de cardinalidade** — o middleware rotula pela rota registrada, não
pelo path concreto:

```python
route = request.scope.get("route")
endpoint = getattr(route, "path", request.url.path)
REQUEST_LATENCY.labels(request.method, endpoint).observe(elapsed)
```

Sem esse cuidado, `/items/1`, `/items/2`, … gerariam séries temporais distintas,
levando à explosão de cardinalidade no Prometheus.

### 5.3 Ciclo de vida

```python
@asynccontextmanager
async def lifespan(_app: FastAPI):
    if BOOT_DELAY > 0:
        time.sleep(BOOT_DELAY)
    READY.set(1)
    yield
    READY.set(0)          # sai do balanceamento antes do encerramento
```

Utiliza `lifespan` em vez de `@app.on_event`, deprecado nas versões atuais do
FastAPI.

### 5.4 Suíte de testes

📄 `cicd/app/test_main.py` — 87 linhas, 8 casos

| Caso | Verifica |
|---|---|
| `test_health` | Liveness responde 200 |
| `test_ready_apos_startup` | Readiness 200 dentro do context manager |
| `test_ready_503_antes_do_startup` | Recusa tráfego antes do lifespan |
| `test_root_tem_versao` | Metadados expostos |
| `test_work_respeita_ms` | Parâmetro de latência |
| `test_metrics_expoe_prometheus` | Métricas presentes no formato correto |
| `test_metrics_nao_explode_cardinalidade` | Query string não vira label |
| `test_version_nunca_vazia` | **Regressão** — ver seção 13 |

**Execução:**

```bash
wsl -d Ubuntu-24.04 -u root -- bash \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/validate.sh
```

```
8 passed, 1 warning in 0.57s
```

---

## 6. Implementação — Containerização

📄 `cicd/app/Dockerfile`

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
RUN useradd -u 10001 -m appuser
WORKDIR /app
COPY --from=builder /install /usr/local
COPY main.py .
USER 10001
EXPOSE 8000
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

| Prática | Implementação | Motivo |
|---|---|---|
| Multi-stage build | `builder` + runtime | Toolchain de compilação ausente na imagem final |
| Usuário não-privilegiado | `USER 10001` (UID numérico) | Compatível com `runAsNonRoot` — o Kubernetes não resolve nomes |
| Dependências fixadas | `fastapi==0.115.6` etc. | Builds reproduzíveis |
| Versão injetada em build | `ARG APP_VERSION` | Rastreabilidade em runtime |
| Contexto reduzido | `.dockerignore` | Exclui testes e caches |

---

## 7. Implementação — Manifestos Kubernetes

📁 `cicd/k8s/base/`

### 7.1 Deployment — 82 linhas

**Estratégia de atualização:**

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

`maxUnavailable: 0` garante que a capacidade nominal nunca seja reduzida durante
o rollout: o pod novo precisa passar pela readiness antes que o antigo seja
encerrado.

**Distribuição topológica:**

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: demo-api
```

`ScheduleAnyway` (e não `DoNotSchedule`) porque em cluster de 3 nós a restrição
rígida poderia impedir o scheduling.

**Contexto de segurança:**

```yaml
securityContext:                    # nível do pod
  runAsNonRoot: true
  runAsUser: 10001
  seccompProfile:
    type: RuntimeDefault
# ...
securityContext:                    # nível do container
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

**Probes:**

```yaml
startupProbe:
  httpGet: { path: /health, port: http }
  periodSeconds: 2
  failureThreshold: 30              # 60 s de tolerância na inicialização

readinessProbe:
  httpGet: { path: /ready, port: http }
  periodSeconds: 5
  timeoutSeconds: 2

livenessProbe:
  httpGet: { path: /health, port: http }
  periodSeconds: 10
  timeoutSeconds: 2
  failureThreshold: 3
```

**Encerramento gracioso:**

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 5"]
terminationGracePeriodSeconds: 30
```

O `preStop` cobre a janela de propagação da remoção do endpoint entre os
`kube-proxy` de todos os nós — sem ele, conexões podem ser roteadas para um pod
já em encerramento.

**Anotações de scraping:**

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8000"
  prometheus.io/path: "/metrics"
```

### 7.2 Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-api
spec:
  selector:
    app: demo-api
  ports:
    - name: http
      port: 80
      targetPort: http          # referência nominal, não numérica
```

### 7.3 PodDisruptionBudget

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: demo-api
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: demo-api
```

---

## 8. Implementação — Gestão de configuração (Kustomize)

### 8.1 Estrutura

```
k8s/
├── base/kustomization.yaml
└── overlays/
    ├── dev/kustomization.yaml
    └── prod/kustomization.yaml
```

### 8.2 Base

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - pdb.yaml
labels:
  - includeSelectors: true
    pairs:
      app.kubernetes.io/name: demo-api
      app.kubernetes.io/managed-by: argocd
```

> Migrado de `commonLabels`, deprecado nas versões atuais do Kustomize.

### 8.3 Overlay dev

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo-dev
resources:
  - ../../base
images:
  - name: ghcr.io/mateusjacomine/demo-api
    newTag: 7962b92                       # atualizado pelo pipeline
replicas:
  - name: demo-api
    count: 1
labels:
  - includeSelectors: false
    pairs:
      app.kubernetes.io/version: dev
      environment: dev
patches:
  - target:
      kind: Deployment
      name: demo-api
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env/0/value
        value: "7962b92"  # APP_VERSION
```

### 8.4 Overlay prod

Diferenças: `namespace: demo-prod`, `count: 2`, `requests.cpu: 100m`.

### 8.5 Verificação da renderização

```bash
kubectl kustomize cicd/k8s/overlays/dev
kubectl kustomize cicd/k8s/overlays/dev | kubectl apply --dry-run=server -f -
```

```
service/demo-api created (server dry run)
deployment.apps/demo-api created (server dry run)
poddisruptionbudget.policy/demo-api created (server dry run)
```

---

## 9. Implementação — Continuous Integration

📄 `.github/workflows/ci-cd.yaml` — 124 linhas

### 9.1 Gatilhos

```yaml
on:
  push:
    branches: [main]
    paths:
      - 'cicd/app/**'
      - 'cicd/k8s/**'
      - '.github/workflows/ci-cd.yaml'
  pull_request:
    branches: [main]
    paths:
      - 'cicd/app/**'
```

Filtros de path evitam execuções desnecessárias em alterações de documentação.
Pull requests executam somente o job `test`.

### 9.2 Job `test`

```yaml
test:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v5
      with:
        python-version: '3.12'
        cache: pip
        cache-dependency-path: cicd/app/requirements.txt
    - name: Instalar dependencias
      working-directory: cicd/app
      run: |
        pip install -r requirements.txt
        pip install pytest httpx ruff
    - name: Lint
      working-directory: cicd/app
      run: ruff check . || true
    - name: Testes
      working-directory: cicd/app
      run: pytest -q
```

### 9.3 Job `build`

```yaml
build:
  needs: test
  if: github.event_name == 'push'
  permissions:
    contents: read
    packages: write
  outputs:
    image_tag: ${{ steps.meta.outputs.short_sha }}
  steps:
    - uses: actions/checkout@v4
    - name: Definir tag imutavel
      id: meta
      run: echo "short_sha=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"
    - uses: docker/setup-buildx-action@v3
    - name: Login no GHCR
      uses: docker/login-action@v3
      with:
        registry: ghcr.io
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}
    - name: Build e push
      uses: docker/build-push-action@v6
      with:
        context: cicd/app
        push: true
        tags: |
          ghcr.io/${{ github.repository_owner }}/demo-api:${{ steps.meta.outputs.short_sha }}
          ghcr.io/${{ github.repository_owner }}/demo-api:latest
        build-args: APP_VERSION=${{ steps.meta.outputs.short_sha }}
        cache-from: type=gha
        cache-to: type=gha,mode=max
```

Autenticação via `GITHUB_TOKEN` efêmero, com permissão mínima
(`packages: write`) — sem PAT de longa duração.

### 9.4 Job `update-manifest`

```yaml
update-manifest:
  needs: build
  permissions:
    contents: write
  steps:
    - uses: actions/checkout@v4
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
    - name: Atualizar tag da imagem no overlay de dev
      working-directory: cicd/k8s/overlays/dev
      run: |
        TAG="${{ needs.build.outputs.image_tag }}"
        sed -i "s|newTag: .*|newTag: ${TAG}|" kustomization.yaml
        sed -i "s|value: \".*\"  # APP_VERSION|value: \"${TAG}\"  # APP_VERSION|" kustomization.yaml
    - name: Commit
      run: |
        git config user.name  "github-actions[bot]"
        git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
        if git diff --quiet; then exit 0; fi
        git add cicd/k8s/overlays/dev/kustomization.yaml
        git commit -m "deploy(dev): ${{ needs.build.outputs.image_tag }} [skip ci]"
        git push
```

**`[skip ci]`** interrompe a recursão: sem esse marcador o commit do bot
dispararia novo pipeline indefinidamente.

**`git diff --quiet`** torna o job idempotente — reexecuções sem alteração real
não geram commits vazios.

---

## 10. Implementação — Continuous Delivery (Argo CD)

### 10.1 Instalação

📄 `cicd/argocd/install.sh`

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml

kubectl -n argocd wait --for=condition=Available deployment --all --timeout=600s

kubectl -n argocd patch svc argocd-server -p \
  '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"targetPort":8080,"nodePort":30443}]}}'
```

Componentes instalados:

| Componente | Responsabilidade |
|---|---|
| `argocd-application-controller` | Loop de reconciliação |
| `argocd-repo-server` | Clone do repo e renderização do Kustomize |
| `argocd-server` | API e interface web |
| `argocd-redis` | Cache de manifestos renderizados |
| `argocd-dex-server` | Federação de identidade (não utilizado) |
| `argocd-applicationset-controller` | Geração dinâmica de Applications |
| `argocd-notifications-controller` | Notificações |

### 10.2 Application — desenvolvimento

📄 `cicd/argocd/application-dev.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-api-dev
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/mateusjacomine/k8s-gitops-lab.git
    targetRevision: main
    path: cicd/k8s/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

| Parâmetro | Efeito |
|---|---|
| `prune: true` | Remove do cluster recursos excluídos do Git |
| `selfHeal: true` | Reverte alterações imperativas |
| `CreateNamespace=true` | Cria o namespace de destino |
| `PrunePropagationPolicy=foreground` | Aguarda a remoção de dependentes |
| `finalizers` | Cascata na exclusão da Application |
| `retry.backoff` | Retentativa exponencial: 5 s → 3 min |

### 10.3 Application — produção

Idêntica, exceto pela ausência de `syncPolicy.automated`:

```yaml
  syncPolicy:
    # SEM 'automated': producao exige sync manual.
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
```

### 10.4 Registro

📄 `cicd/bootstrap.sh`

```bash
REPO_URL="${REPO_URL:-https://github.com/mateusjacomine/k8s-gitops-lab.git}"

for env in dev prod; do
  sed "s|repoURL: .*|repoURL: ${REPO_URL}|" "$DIR/argocd/application-${env}.yaml" \
    | kubectl apply -f -
done
```

---

## 11. Procedimento de instalação completo

### Pré-requisitos

- Cluster Kubernetes ≥ 1.28 operacional
- `kubectl` configurado
- `gh` CLI autenticado
- Conta GitHub com Actions habilitado

### Etapa 1 — Argo CD

```bash
wsl -d Ubuntu-24.04 -u root -- bash \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/argocd/install.sh
```

**Saída esperada:**

```
==> Argo CD instalado
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          81s
argocd-applicationset-controller-64f6bd6456-rtjxp   1/1     Running   0          81s
argocd-dex-server-5fdcd9df8b-qr5ch                  1/1     Running   0          81s
argocd-notifications-controller-778495d96f-srk8n    1/1     Running   0          81s
argocd-redis-69fd8bd669-7z44w                       1/1     Running   0          81s
argocd-repo-server-75567c944-ddvvn                  1/1     Running   0          81s
argocd-server-5c768cdd96-bn5bk                      1/1     Running   0          81s
```

### Etapa 2 — Validação local

```bash
wsl -d Ubuntu-24.04 -u root -- bash \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/validate.sh
```

### Etapa 3 — Publicação do repositório

```bash
cd C:\Users\Mateus\PycharmProjects\Projeto_Entrevista
git init
git add -A
git commit -m "feat: esteira GitOps"
git branch -M main
gh repo create k8s-gitops-lab --public --source=. --remote=origin --push
```

### Etapa 4 — Registro das Applications

```bash
wsl -d Ubuntu-24.04 -u root -- bash \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/bootstrap.sh
```

### Etapa 5 — Verificação

```bash
kubectl -n argocd get applications
kubectl -n demo-dev get pods
gh run list --limit 3
```

### Etapa 6 — Acesso à interface

```
URL:     https://192.168.172.130:30443
usuário: admin
```

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## 12. Validação e evidências

### 12.1 Pipeline

```bash
gh run list --limit 3
```

```
completed  success  fix(app): APP_VERSION vazia derrubava...  CI/CD  main  push  57s
completed  success  docs(cicd): README da esteira e script    CI/CD  main  push  1m24s
```

### 12.2 Commit automatizado

```bash
git log --oneline -5
```

```
4dd2d33 docs: guia completo da esteira CI/CD explicada do zero
13335a2 docs: remove senha do Argo CD dos READMEs
9996db7 deploy(dev): 7962b92 [skip ci]        ← github-actions[bot]
7962b92 fix(app): APP_VERSION vazia derrubava o container no boot
38cc2d6 deploy(dev): 35d7f93 [skip ci]        ← github-actions[bot]
```

### 12.3 Registry

```bash
gh api user/packages/container/demo-api --jq '.visibility'
gh api user/packages/container/demo-api/versions --jq '.[0].metadata.container.tags'
```

```
public
["7962b92","latest"]
```

### 12.4 Estado do cluster

```bash
kubectl -n argocd get applications
```

```
NAME            SYNC STATUS   HEALTH STATUS   PATH
demo-api-dev    Synced        Healthy         cicd/k8s/overlays/dev
demo-api-prod   OutOfSync     Missing         cicd/k8s/overlays/prod
```

```bash
kubectl -n demo-dev get all
```

```
pod/demo-api-558d884996-qbhpf   1/1   Running   0     141m
service/demo-api   ClusterIP   10.109.174.225   <none>   80/TCP   146m
deployment.apps/demo-api   1/1   1   1   146m
```

### 12.5 Rastreabilidade commit → runtime

```bash
kubectl -n demo-dev get deploy demo-api \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

```
ghcr.io/mateusjacomine/demo-api:7962b92
```

```bash
kubectl -n demo-dev run curl --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- curl -s http://demo-api/
```

```json
{"app":"demo-api","version":"7962b92","uptime_s":6675.8}
```

A tag da imagem, o `APP_VERSION` em runtime e o SHA do commit são o mesmo valor.

### 12.6 Instrumentação

```bash
kubectl -n demo-dev run m --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- curl -s http://demo-api/metrics
```

131 linhas expostas. Amostra:

```
app_info{version="7962b92"} 1.0
http_requests_total{endpoint="/health",method="GET",status="200"} 5.0
http_requests_total{endpoint="/ready",method="GET",status="200"} 8.0
http_request_duration_seconds_bucket{endpoint="/health",le="0.005",method="GET"} 5.0
```

### 12.7 Teste de reconciliação (self-heal)

**Procedimento:**

```bash
kubectl -n demo-dev get deploy demo-api -o jsonpath='{.spec.replicas}'
# 1

kubectl -n demo-dev scale deployment demo-api --replicas=5
kubectl -n demo-dev get deploy demo-api -o jsonpath='{.spec.replicas}'
# 5
```

**Resultado:**

```
selfHeal atuou apos ~5s: replicas de volta para 1

NAME       READY   UP-TO-DATE   AVAILABLE   AGE
demo-api   1/1     1            1           6m45s

NAME           SYNC STATUS   HEALTH STATUS
demo-api-dev   Synced        Healthy
```

Divergência introduzida imperativamente foi revertida em aproximadamente 5
segundos, sem intervenção.

---

## 13. Incidente: análise de causa raiz

### 13.1 Resumo

| Campo | Valor |
|---|---|
| Sintoma | `CrashLoopBackOff` no primeiro deploy |
| Detecção | `kubectl get pods` após sincronização |
| Impacto | Ambiente dev indisponível (~4 min) |
| Causa raiz | Variável de ambiente vazia por propagação de label |
| Correção | Duas camadas + teste de regressão |

### 13.2 Detecção

```bash
kubectl -n demo-dev get pods
```

```
NAME                        READY   STATUS             RESTARTS
demo-api-6dcd7fcc66-hfttc   0/1     CrashLoopBackOff   3
```

### 13.3 Diagnóstico

```bash
kubectl -n demo-dev describe pod demo-api-6dcd7fcc66-hfttc | grep -A5 'Last State'
```

```
Last State:     Terminated
  Reason:       Error
  Exit Code:    1
```

Exit code 1 indica falha da aplicação, não OOM (137) nem SIGTERM (143).

```bash
kubectl -n demo-dev logs demo-api-6dcd7fcc66-hfttc --previous
```

```
File "/app/main.py", line 61, in <module>
    app = FastAPI(title="demo-api", version=VERSION, lifespan=lifespan)
  File ".../fastapi/applications.py", line 876, in __init__
    assert self.version, "A version must be provided for OpenAPI, e.g.: '2.1.0'"
AssertionError: A version must be provided for OpenAPI, e.g.: '2.1.0'
```

> `--previous` é obrigatório em `CrashLoopBackOff`: o container corrente pode não
> existir no momento da consulta.

### 13.4 Causa raiz

Configuração original:

```yaml
env:
  - name: APP_VERSION
    valueFrom:
      fieldRef:
        fieldPath: metadata.labels['app.kubernetes.io/version']
```

O label era aplicado pelo Kustomize com `includeSelectors: false`. Nessa
configuração o label **não é propagado ao pod template**, e o `fieldRef` resolve
para string vazia.

**Fator agravante** — a proteção no código era ineficaz:

```python
VERSION = os.getenv("APP_VERSION", "dev")
```

O segundo argumento de `os.getenv` é acionado apenas quando a variável **não
existe**. Variável existente com valor vazio retorna `""`:

```python
os.getenv("INEXISTENTE", "dev")   # → "dev"
os.getenv("VAZIA", "dev")         # → ""
```

O FastAPI valida `version` por asserção no construtor, abortando o import.

### 13.5 Correção

**Camada 1 — aplicação:**

```python
# or "dev" cobre APP_VERSION definido porem VAZIO — o default do getenv
# so age quando a variavel nao existe.
VERSION = os.getenv("APP_VERSION") or "dev"
```

**Camada 2 — manifesto:** substituição do `fieldRef` por valor literal,
atualizado pelo pipeline em conjunto com a tag da imagem.

**Camada 3 — teste de regressão:**

```python
def test_version_nunca_vazia():
    """
    Roda em subprocesso: recarregar o modulo no processo atual quebraria o
    registry global do prometheus_client (metricas duplicadas).
    """
    codigo = (
        "import os; os.environ['APP_VERSION'] = ''; "
        "import main; "
        "assert main.VERSION, 'VERSION vazia'; "
        "assert main.app.version, 'app.version vazia'; "
    )
    r = subprocess.run([sys.executable, "-c", codigo], capture_output=True, text=True, ...)
    assert r.returncode == 0
```

A primeira implementação do teste usava `importlib.reload`, que falhava com
`ValueError: Duplicated timeseries` — o `prometheus_client` mantém registry
global. Subprocesso isola o estado.

### 13.6 Verificação

```
NAME                        READY   STATUS    RESTARTS   AGE
demo-api-558d884996-qbhpf   1/1     Running   0          107s
```

```json
{"app":"demo-api","version":"7962b92","uptime_s":18.9}
```

### 13.7 Lições

1. **Semântica de default em `os.getenv`** não cobre valor vazio — distinção
   relevante em qualquer configuração por variável de ambiente.
2. **`fieldRef` sobre labels** depende de como a ferramenta de templating os
   propaga; valores literais são mais previsíveis.
3. **Falhas de integração não aparecem em teste unitário** — só o deploy real
   expôs o problema.
4. **Registries globais** (como o do `prometheus_client`) exigem isolamento por
   processo em testes que reimportam módulos.

---

## 14. Operação

### 14.1 Fluxo padrão de deploy

```bash
# 1. Alteração no código
vim cicd/app/main.py

# 2. Validação local
wsl -d Ubuntu-24.04 -u root -- bash .../cicd/validate.sh

# 3. Commit e push
git add -A
git commit -m "feat: descricao"
git push

# 4. Acompanhamento
gh run watch
kubectl -n argocd get app demo-api-dev -w
kubectl -n demo-dev get pods -w
```

> `kubectl apply` **não** faz parte do fluxo de deploy. Aplicação imperativa é
> revertida pelo `selfHeal`.

### 14.2 Promoção para produção

```bash
# 1. Copiar a tag validada em dev
vim cicd/k8s/overlays/prod/kustomization.yaml

git add -A && git commit -m "promote(prod): <sha>" && git push

# 2. Sincronização manual
kubectl -n argocd patch app demo-api-prod --type merge \
  -p '{"operation":{"sync":{"revision":"main"}}}'

# 3. Verificação
kubectl -n argocd get app demo-api-prod
kubectl -n demo-prod get pods
```

### 14.3 Rollback

```bash
git revert <sha-do-commit-problematico>
git push
```

O pipeline reconstrói a versão anterior e o Argo CD reconcilia. Rollback fica
registrado no histórico com autor e justificativa.

**Alternativa — rollback direto no Argo CD:**

```bash
argocd app rollback demo-api-dev <revision>
```

> Cria divergência com o Git; o `selfHeal` reverterá na próxima reconciliação.
> Use apenas em emergência, seguido de correção no repositório.

### 14.4 Diagnóstico

| Sintoma | Comando |
|---|---|
| Estado geral | `kubectl -n argocd get applications` |
| Detalhe da divergência | `kubectl -n argocd describe app demo-api-dev` |
| Pods com problema | `kubectl -n demo-dev get pods` |
| Eventos do pod | `kubectl -n demo-dev describe pod <nome>` |
| Log do container anterior | `kubectl -n demo-dev logs <nome> --previous` |
| Execuções do pipeline | `gh run list --limit 5` |
| Log de execução | `gh run view <id> --log-failed` |
| Forçar reconciliação | `kubectl -n argocd patch app demo-api-dev --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'` |

### 14.5 Rotação da senha do Argo CD

```bash
# Gerar hash bcrypt e aplicar
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData":{"admin.password":"<bcrypt-hash>","admin.passwordMtime":"'$(date +%FT%T%Z)'"}}'

# Remover o secret inicial
kubectl -n argocd delete secret argocd-initial-admin-secret
```

---

## 15. Segurança

### 15.1 Controles implementados

| Camada | Controle | Implementação |
|---|---|---|
| Imagem | Usuário não-privilegiado | `USER 10001` |
| Imagem | Superfície reduzida | Multi-stage; sem toolchain no runtime |
| Pod | Bloqueio de root | `runAsNonRoot: true` |
| Pod | Perfil seccomp | `seccompProfile: RuntimeDefault` |
| Container | Sem escalada | `allowPrivilegeEscalation: false` |
| Container | FS somente leitura | `readOnlyRootFilesystem: true` |
| Container | Capabilities | `drop: ["ALL"]` |
| CI | Token efêmero | `secrets.GITHUB_TOKEN` |
| CI | Permissão mínima | `packages: write` apenas no job de build |
| Arquitetura | Sem credencial de cluster no CI | Modelo pull |
| Repositório | Sem segredos versionados | `.gitignore` + varredura |

### 15.2 Verificação de segredos antes da publicação

```bash
git grep -nIE "(password|senha|token|secret)[\"' ]*[:=]" -- $(git diff --cached --name-only)
```

Achados tratados:

- `.claude/settings.local.json` — removido do versionamento
- Senha do Argo CD nos READMEs — substituída pelo comando de leitura do secret
- Senha `vagrant` em `ks.cfg` — mantida (lab isolado em NAT, sem exposição)

### 15.3 Riscos residuais

| Risco | Severidade | Mitigação |
|---|---|---|
| Certificado autoassinado no Argo CD | Baixa | Aceitável em lab; usar cert-manager em produção |
| Senha inicial do Argo CD não rotacionada | Média | Procedimento em 14.5 |
| Ausência de scan de vulnerabilidade nas imagens | Média | Adicionar Trivy ao pipeline |
| Imagens sem assinatura | Média | Cosign + verificação por policy |
| Sem NetworkPolicy nos namespaces da app | Baixa | Calico disponível; declarar policies |
| Registry público | Baixa | Intencional; imagem sem dados sensíveis |

---

## 16. Limitações conhecidas e roadmap

### 16.1 Limitações

1. **Escopo restrito ao ambiente dev no pipeline** — a promoção para produção
   exige edição manual do overlay.
2. **Polling de 3 minutos** — sem webhook configurado, a latência de detecção
   pode chegar a 3 minutos.
3. **Ausência de gates de qualidade** — sem cobertura mínima, análise estática
   bloqueante ou scan de dependências.
4. **Sem observabilidade da esteira** — Prometheus não instalado; a aplicação
   expõe métricas que ainda não são coletadas.
5. **Cluster de nó único no control-plane** — sem alta disponibilidade do etcd.

### 16.2 Evolução proposta

| Prioridade | Item | Justificativa |
|---|---|---|
| Alta | Instalar kube-prometheus-stack | A instrumentação já existe e não é coletada |
| Alta | Webhook GitHub → Argo CD | Reduz latência de minutos para segundos |
| Alta | Trivy no pipeline | Detecção de CVEs antes do deploy |
| Média | Argo Rollouts (canary) | Deploy progressivo com análise automática |
| Média | Sealed Secrets ou External Secrets | Gestão de segredos versionáveis |
| Média | Promoção automatizada dev → prod | Via PR gerado por pipeline |
| Baixa | Cosign | Assinatura e verificação de imagens |
| Baixa | ApplicationSet | Escala para múltiplos serviços |

---

## 17. Referência de comandos

### Instalação

```bash
# Argo CD
bash cicd/argocd/install.sh

# Registro das Applications
bash cicd/bootstrap.sh

# Validação local
bash cicd/validate.sh
```

### Operação diária

```bash
git add -A && git commit -m "feat: ..." && git push
gh run watch
kubectl -n argocd get app demo-api-dev -w
kubectl -n demo-dev get pods -w
```

### Inspeção

```bash
kubectl -n argocd get applications
kubectl -n argocd describe app demo-api-dev
kubectl -n demo-dev get all
kubectl -n demo-dev get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl kustomize cicd/k8s/overlays/dev
```

### Diagnóstico

```bash
kubectl -n demo-dev describe pod <nome>
kubectl -n demo-dev logs <nome> --previous
kubectl -n demo-dev get events --sort-by=.metadata.creationTimestamp
gh run view <id> --log-failed
```

### Sincronização

```bash
# Forçar refresh
kubectl -n argocd patch app demo-api-dev --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Sync manual (produção)
kubectl -n argocd patch app demo-api-prod --type merge \
  -p '{"operation":{"sync":{"revision":"main"}}}'
```

### Demonstrações

```bash
# Self-healing
kubectl -n demo-dev scale deployment demo-api --replicas=5
kubectl -n demo-dev get deploy demo-api -w

# Rollback
git revert HEAD && git push

# Teste funcional
kubectl -n demo-dev run curl --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- curl -s http://demo-api/
```

### Credenciais

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Anexo A — Glossário técnico

| Termo | Definição |
|---|---|
| **GitOps** | Modelo operacional em que o estado desejado da infraestrutura é declarado em Git e reconciliado continuamente por um agente automatizado |
| **Reconciliação** | Ciclo de comparação entre estado desejado (Git) e observado (cluster), com aplicação das diferenças |
| **Drift** | Divergência entre o estado declarado e o efetivo, tipicamente por alteração imperativa |
| **Self-heal** | Correção automática de drift pelo agente de reconciliação |
| **Prune** | Remoção de recursos existentes no cluster e ausentes na fonte declarativa |
| **Tag imutável** | Identificador de imagem nunca reatribuído, garantindo correspondência unívoca com um artefato |
| **Overlay** | Camada de customização aplicada sobre uma base Kustomize |
| **Rolling update** | Substituição incremental de réplicas preservando disponibilidade |
| **PDB** | PodDisruptionBudget — limite de indisponibilidade tolerada em disrupções voluntárias |
| **Probe** | Verificação periódica de estado executada pelo kubelet |
| **Cardinalidade** | Número de séries temporais distintas geradas por uma métrica |
| **CFS quota** | Mecanismo do kernel que impõe limite de CPU por período, causando throttling |

---

## Anexo B — Arquivos de referência

| Arquivo | Linhas | Descrição |
|---|---|---|
| `cicd/app/main.py` | 120 | Aplicação FastAPI instrumentada |
| `cicd/app/test_main.py` | 87 | Suíte de 8 testes |
| `cicd/app/Dockerfile` | 18 | Build multi-stage |
| `cicd/k8s/base/deployment.yaml` | 82 | Deployment com probes e security context |
| `cicd/k8s/base/service.yaml` | 13 | Service ClusterIP |
| `cicd/k8s/base/pdb.yaml` | 11 | PodDisruptionBudget |
| `cicd/k8s/overlays/dev/kustomization.yaml` | 27 | Overlay de desenvolvimento |
| `cicd/k8s/overlays/prod/kustomization.yaml` | 29 | Overlay de produção |
| `.github/workflows/ci-cd.yaml` | 124 | Pipeline de CI/CD |
| `cicd/argocd/application-dev.yaml` | 32 | Application com auto-sync |
| `cicd/argocd/application-prod.yaml` | 31 | Application com sync manual |

---

**Documento gerado a partir do ambiente em execução.** Todas as saídas de
comando reproduzidas foram capturadas do cluster operacional, não estimadas.
