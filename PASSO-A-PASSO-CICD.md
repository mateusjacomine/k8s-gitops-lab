# Passo a Passo — Implementando a Esteira CI/CD do Zero

> **Como usar este documento:** siga as etapas na ordem. Cada comando tem a
> saída esperada logo abaixo. Se a sua saída for diferente, pare e veja a seção
> [Quando dá errado](#quando-dá-errado) daquela etapa.
>
> **Tempo total:** ~40 minutos (a maior parte é espera de download).

---

## Índice

- [Antes de começar](#antes-de-começar)
- [ETAPA 1 — Criar a aplicação](#etapa-1--criar-a-aplicação)
- [ETAPA 2 — Escrever os testes](#etapa-2--escrever-os-testes)
- [ETAPA 3 — Containerizar](#etapa-3--containerizar)
- [ETAPA 4 — Criar os manifestos Kubernetes](#etapa-4--criar-os-manifestos-kubernetes)
- [ETAPA 5 — Configurar dev e prod com Kustomize](#etapa-5--configurar-dev-e-prod-com-kustomize)
- [ETAPA 6 — Instalar o Argo CD](#etapa-6--instalar-o-argo-cd)
- [ETAPA 7 — Criar o pipeline no GitHub Actions](#etapa-7--criar-o-pipeline-no-github-actions)
- [ETAPA 8 — Publicar o repositório](#etapa-8--publicar-o-repositório)
- [ETAPA 9 — Registrar as Applications](#etapa-9--registrar-as-applications)
- [ETAPA 10 — Validar tudo](#etapa-10--validar-tudo)
- [Fluxo do dia a dia](#fluxo-do-dia-a-dia)
- [Quando dá errado](#quando-dá-errado)

---

## Antes de começar

### Pré-requisitos

Rode estes comandos. Todos precisam responder algo.

```bash
kubectl get nodes          # cluster funcionando
git --version              # git instalado
gh auth status             # GitHub CLI autenticado
```

**Saída esperada do primeiro:**

```
NAME      STATUS   ROLES           AGE   VERSION
k8s-cp1   Ready    control-plane   46h   v1.31.14
k8s-w1    Ready    <none>          46h   v1.31.14
k8s-w2    Ready    <none>          46h   v1.31.14
```

Se `gh auth status` falhar:

```bash
gh auth login
```

### Onde rodar os comandos

Neste ambiente há duas opções. Os exemplos usam WSL porque os scripts são bash.

```bash
# Opção A — entrar no WSL e trabalhar lá
wsl -d Ubuntu-24.04
cd /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista

# Opção B — chamar do PowerShell, comando a comando
wsl -d Ubuntu-24.04 -u root -- kubectl get nodes
```

### Criar a estrutura de pastas

```bash
cd /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista

mkdir -p cicd/app \
         cicd/k8s/base \
         cicd/k8s/overlays/dev \
         cicd/k8s/overlays/prod \
         cicd/argocd \
         .github/workflows
```

**Conferir:**

```bash
find cicd .github -type d | sort
```

```
.github
.github/workflows
cicd
cicd/app
cicd/argocd
cicd/k8s
cicd/k8s/base
cicd/k8s/overlays
cicd/k8s/overlays/dev
cicd/k8s/overlays/prod
```

---

## ETAPA 1 — Criar a aplicação

### 1.1 · Declarar as dependências

```bash
cat > cicd/app/requirements.txt <<'EOF'
fastapi==0.115.6
uvicorn[standard]==0.34.0
prometheus-client==0.21.1
EOF
```

> Versões fixadas (`==`) e não faixas (`>=`). Build reproduzível: o mesmo
> commit gera sempre a mesma imagem.

### 1.2 · Escrever a aplicação

Crie `cicd/app/main.py`. As partes que importam, na ordem:

**Imports e configuração:**

```python
import os
import random
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest,
)

# or "dev" cobre APP_VERSION definido porem VAZIO — o default do getenv
# so age quando a variavel nao existe.
VERSION = os.getenv("APP_VERSION") or "dev"
BOOT_DELAY = float(os.getenv("BOOT_DELAY_SECONDS", "0"))
```

> ⚠️ **`or "dev"` e não `os.getenv("APP_VERSION", "dev")`.** Essa diferença
> derrubou a aplicação em produção — veja [Quando dá errado](#etapa-10-o-pod-fica-em-crashloopbackoff).

**Métricas:**

```python
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Latencia das requisicoes HTTP",
    ["method", "endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
REQUEST_COUNT = Counter(
    "http_requests_total", "Total de requisicoes HTTP",
    ["method", "endpoint", "status"],
)
APP_INFO = Gauge("app_info", "Metadados da aplicacao", ["version"])
READY = Gauge("app_ready", "1 quando a aplicacao esta pronta")

APP_INFO.labels(version=VERSION).set(1)
READY.set(0)
_started_at = time.time()
```

**Ciclo de vida — o que controla a readiness:**

```python
@asynccontextmanager
async def lifespan(_app: FastAPI):
    if BOOT_DELAY > 0:
        time.sleep(BOOT_DELAY)
    READY.set(1)          # só agora aceita tráfego
    yield
    READY.set(0)          # ao desligar, sai do balanceamento primeiro

app = FastAPI(title="demo-api", version=VERSION, lifespan=lifespan)
```

**Middleware de métricas:**

```python
@app.middleware("http")
async def track_metrics(request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start

    # Usa a rota registrada (/items/{id}), nao o path concreto,
    # para nao explodir a cardinalidade da metrica.
    route = request.scope.get("route")
    endpoint = getattr(route, "path", request.url.path)

    REQUEST_LATENCY.labels(request.method, endpoint).observe(elapsed)
    REQUEST_COUNT.labels(request.method, endpoint, response.status_code).inc()
    return response
```

**Endpoints:**

```python
@app.get("/")
def root():
    return {"app": "demo-api", "version": VERSION,
            "uptime_s": round(time.time() - _started_at, 1)}

@app.get("/health")
def health():
    """Liveness: responde enquanto o processo estiver vivo."""
    return {"status": "ok"}

@app.get("/ready")
def ready():
    """Readiness: 503 enquanto nao terminou o boot."""
    if READY._value.get() < 1:
        return Response(content='{"status":"starting"}', status_code=503,
                        media_type="application/json")
    return {"status": "ready"}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
```

### 1.3 · Verificar

```bash
python3 -c "import ast; ast.parse(open('cicd/app/main.py').read()); print('sintaxe OK')"
```

```
sintaxe OK
```

---

## ETAPA 2 — Escrever os testes

### 2.1 · Criar o arquivo de testes

Crie `cicd/app/test_main.py`:

```python
"""Testes que rodam no CI antes de qualquer build."""
import os

from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_ready_apos_startup():
    # O lifespan so roda dentro do context manager
    with TestClient(app) as c:
        r = c.get("/ready")
        assert r.status_code == 200


def test_ready_503_antes_do_startup():
    """Sem o lifespan, /ready deve recusar trafego."""
    r = client.get("/ready")
    assert r.status_code == 503


def test_metrics_expoe_prometheus():
    client.get("/health")
    corpo = client.get("/metrics").text
    assert "http_request_duration_seconds" in corpo
    assert "app_info" in corpo
```

### 2.2 · Preparar o ambiente de teste

```bash
sudo apt-get install -y python3.12-venv
python3 -m venv /opt/venv-cicd
/opt/venv-cicd/bin/pip install -q -r cicd/app/requirements.txt pytest httpx
```

### 2.3 · Rodar

```bash
cd cicd/app && /opt/venv-cicd/bin/python -m pytest -q; cd -
```

**Saída esperada:**

```
....                                                     [100%]
4 passed in 0.34s
```

> ✅ **Checkpoint:** se os testes passam, a aplicação está correta. Só continue
> daqui.

---

## ETAPA 3 — Containerizar

### 3.1 · Criar o Dockerfile

```bash
cat > cicd/app/Dockerfile <<'EOF'
# ETAPA 1 — instala dependencias (fica so aqui, nao vai pra imagem final)
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ETAPA 2 — imagem final, enxuta
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
EOF
```

### 3.2 · Excluir lixo do contexto de build

```bash
cat > cicd/app/.dockerignore <<'EOF'
__pycache__/
*.pyc
.pytest_cache/
test_*.py
EOF
```

> **Por que `USER 10001` (número) e não `USER appuser` (nome)?** O Kubernetes
> valida `runAsNonRoot` **antes** de iniciar o container, e nesse momento ele
> não sabe resolver nomes de usuário. Com nome, o pod falha ao subir.

---

## ETAPA 4 — Criar os manifestos Kubernetes

### 4.1 · Deployment

Crie `cicd/k8s/base/deployment.yaml`. As partes decisivas:

**Rollout sem downtime:**

```yaml
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0    # o novo fica Ready ANTES do antigo sair
```

**As três probes:**

```yaml
startupProbe:                        # tolerancia alta no boot
  httpGet: { path: /health, port: http }
  periodSeconds: 2
  failureThreshold: 30               # ate 60s para subir

readinessProbe:                      # falhou -> sai dos Endpoints
  httpGet: { path: /ready, port: http }
  periodSeconds: 5
  timeoutSeconds: 2

livenessProbe:                       # falhou -> REINICIA o container
  httpGet: { path: /health, port: http }
  periodSeconds: 10
  failureThreshold: 3
```

**Variável de ambiente — valor literal, não fieldRef:**

```yaml
env:
  # Sobrescrito por cada overlay com a tag real da imagem.
  # Nao usar fieldRef de label: labels com includeSelectors=false
  # nao chegam ao pod template e a variavel viria vazia.
  - name: APP_VERSION
    value: "dev"
```

**Recursos:**

```yaml
resources:
  requests:
    cpu: 50m
    memory: 96Mi
  limits:
    memory: 192Mi     # sem limit de CPU: evita throttling artificial
```

**Segurança:**

```yaml
securityContext:              # nivel do pod
  runAsNonRoot: true
  runAsUser: 10001
  seccompProfile:
    type: RuntimeDefault
```

```yaml
securityContext:              # nivel do container
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

**Encerramento gracioso:**

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 5"]
terminationGracePeriodSeconds: 30
```

### 4.2 · Service

```bash
cat > cicd/k8s/base/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: demo-api
  labels:
    app: demo-api
spec:
  selector:
    app: demo-api
  ports:
    - name: http
      port: 80
      targetPort: http
EOF
```

### 4.3 · PodDisruptionBudget

```bash
cat > cicd/k8s/base/pdb.yaml <<'EOF'
# maxUnavailable (nao minAvailable) escala junto com o numero de replicas
# e nao trava o drain quando replicas == minAvailable.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: demo-api
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: demo-api
EOF
```

> ⚠️ **Nunca use `minAvailable: 2` com 2 réplicas.** Isso resulta em
> `ALLOWED DISRUPTIONS: 0` e o `kubectl drain` trava para sempre.

### 4.4 · Kustomization da base

```bash
cat > cicd/k8s/base/kustomization.yaml <<'EOF'
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
EOF
```

> Use `labels:` e não `commonLabels:` — o segundo está deprecado e emite aviso.

---

## ETAPA 5 — Configurar dev e prod com Kustomize

### 5.1 · Overlay de desenvolvimento

```bash
cat > cicd/k8s/overlays/dev/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo-dev
resources:
  - ../../base
# A tag e atualizada pelo GitHub Actions a cada push na main.
# E ESTA linha que o Argo CD observa: o commit e o gatilho do deploy.
images:
  - name: ghcr.io/mateusjacomine/demo-api
    newTag: dev
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
        value: "dev"  # APP_VERSION
EOF
```

> 📌 **Troque `mateusjacomine` pelo seu usuário do GitHub.**

### 5.2 · Overlay de produção

```bash
cat > cicd/k8s/overlays/prod/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo-prod
resources:
  - ../../base
images:
  - name: ghcr.io/mateusjacomine/demo-api
    newTag: dev
replicas:
  - name: demo-api
    count: 2
labels:
  - includeSelectors: false
    pairs:
      app.kubernetes.io/version: prod
      environment: prod
patches:
  - target:
      kind: Deployment
      name: demo-api
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/resources/requests/cpu
        value: 100m
      - op: replace
        path: /spec/template/spec/containers/0/env/0/value
        value: "dev"  # APP_VERSION
EOF
```

### 5.3 · Verificar a renderização

```bash
kubectl kustomize cicd/k8s/overlays/dev | grep -E "^kind:|namespace:|image:|replicas:"
```

**Saída esperada:**

```
kind: Service
  namespace: demo-dev
kind: Deployment
  namespace: demo-dev
  replicas: 1
        image: ghcr.io/mateusjacomine/demo-api:dev
kind: PodDisruptionBudget
  namespace: demo-dev
```

### 5.4 · Testar contra o cluster sem aplicar

```bash
kubectl create ns demo-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl kustomize cicd/k8s/overlays/dev | kubectl apply --dry-run=server -f -
```

```
service/demo-api created (server dry run)
deployment.apps/demo-api created (server dry run)
poddisruptionbudget.policy/demo-api created (server dry run)
```

> ✅ **Checkpoint:** os três recursos validaram no servidor. Os manifestos estão
> corretos.

---

## ETAPA 6 — Instalar o Argo CD

Esta é a etapa que você perguntou. São **4 comandos, nesta ordem.**

### Comando 1 · Criar o namespace

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
```

```
namespace/argocd created
```

> O `--dry-run=client | apply` torna o comando idempotente: rodar de novo não
> dá erro de "já existe".

### Comando 2 · Instalar os componentes

```bash
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
```

Saem ~50 linhas de `created`. As últimas:

```
networkpolicy.networking.k8s.io/argocd-repo-server-network-policy created
networkpolicy.networking.k8s.io/argocd-server-network-policy created
```

> Versão fixada (`v2.13.2`) em vez de `stable`. Instalação reproduzível.

### Comando 3 · Esperar ficar pronto

```bash
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=600s
```

**Demora 3–5 minutos na primeira vez** (baixa as imagens).

```
deployment.apps/argocd-applicationset-controller condition met
deployment.apps/argocd-dex-server condition met
deployment.apps/argocd-notifications-controller condition met
deployment.apps/argocd-redis condition met
deployment.apps/argocd-repo-server condition met
deployment.apps/argocd-server condition met
```

### Comando 4 · Expor a interface web

```bash
kubectl -n argocd patch svc argocd-server -p \
  '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"targetPort":8080,"nodePort":30443},{"name":"http","port":80,"targetPort":8080,"nodePort":30080}]}}'
```

```
service/argocd-server patched
```

### Conferir a instalação

```bash
kubectl -n argocd get pods
```

**Saída esperada — 7 pods, todos `Running`:**

```
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          81s
argocd-applicationset-controller-64f6bd6456-rtjxp   1/1     Running   0          81s
argocd-dex-server-5fdcd9df8b-qr5ch                  1/1     Running   0          81s
argocd-notifications-controller-778495d96f-srk8n    1/1     Running   0          81s
argocd-redis-69fd8bd669-7z44w                       1/1     Running   0          81s
argocd-repo-server-75567c944-ddvvn                  1/1     Running   0          81s
argocd-server-5c768cdd96-bn5bk                      1/1     Running   0          81s
```

### Pegar a senha

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

```
YOYVoImMEhKM45Sc
```

### Acessar

```
URL:     https://192.168.172.130:30443
usuário: admin
senha:   (a saída do comando acima)
```

O navegador avisa sobre o certificado — é autoassinado. Clique em
**Avançado → Prosseguir**.

> 💡 **Atalho:** tudo isso está em `cicd/argocd/install.sh`. Para repetir:
> ```bash
> bash cicd/argocd/install.sh
> ```

### 6.5 · Criar os arquivos Application

**Desenvolvimento — sincroniza sozinho:**

```bash
cat > cicd/argocd/application-dev.yaml <<'EOF'
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
      prune: true       # removeu do git -> remove do cluster
      selfHeal: true    # mexeu no cluster -> desfaz
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
```

**Produção — o mesmo, SEM o bloco `automated`:**

```bash
sed 's/demo-api-dev/demo-api-prod/; s|overlays/dev|overlays/prod|; s/demo-dev/demo-prod/' \
  cicd/argocd/application-dev.yaml > cicd/argocd/application-prod.yaml
```

Depois **edite** `cicd/argocd/application-prod.yaml` e remova estas 3 linhas:

```yaml
    automated:
      prune: true
      selfHeal: true
```

Deixando:

```yaml
  syncPolicy:
    # SEM 'automated': producao exige sync manual.
    syncOptions:
      - CreateNamespace=true
```

> **Por quê?** Colocar em produção é uma decisão, não consequência automática de
> um merge.

---

## ETAPA 7 — Criar o pipeline no GitHub Actions

Crie `.github/workflows/ci-cd.yaml` com **3 jobs em sequência**.

### 7.1 · Cabeçalho e gatilhos

```yaml
name: CI/CD

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

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository_owner }}/demo-api
```

> Os filtros de `paths` evitam rodar o pipeline quando você só mexe em
> documentação.

### 7.2 · Job 1 — testar

```yaml
jobs:
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
      - name: Testes
        working-directory: cicd/app
        run: pytest -q
```

### 7.3 · Job 2 — construir e publicar

```yaml
  build:
    needs: test                        # <- só roda se o job test passou
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write                  # necessario para publicar no GHCR
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
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build e push
        uses: docker/build-push-action@v6
        with:
          context: cicd/app
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.short_sha }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
          build-args: APP_VERSION=${{ steps.meta.outputs.short_sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

> `needs: test` é o cadeado. Nada é publicado sem os testes passarem.

### 7.4 · Job 3 — atualizar o manifesto

```yaml
  update-manifest:
    needs: build
    runs-on: ubuntu-latest
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
          if git diff --quiet; then
            echo "nada mudou"
            exit 0
          fi
          git add cicd/k8s/overlays/dev/kustomization.yaml
          git commit -m "deploy(dev): ${{ needs.build.outputs.image_tag }} [skip ci]"
          git push
```

> ⚠️ **`[skip ci]` é obrigatório.** Sem ele, esse commit dispara o pipeline de
> novo, que faz outro commit, que dispara de novo… loop infinito.

---

## ETAPA 8 — Publicar o repositório

### 8.1 · Proteger o que não pode ser versionado

```bash
cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.pytest_cache/
.venv/
venv/
*.log
.idea/
.vscode/
# Nunca versionar kubeconfig ou chaves
kubeconfig
*.kubeconfig
.kube/
*.pem
*.key
id_*
EOF
```

### 8.2 · Inicializar o git

```bash
git init
git add -A
```

### 8.3 · Procurar segredos ANTES de publicar

```bash
git grep -nIE "(password|senha|token|secret)[\"' ]*[:=]" -- $(git diff --cached --name-only)
```

Revise cada linha que aparecer. Se houver segredo real:

```bash
git rm --cached <arquivo>
echo "<arquivo>" >> .gitignore
git add -A
```

> Este passo não é burocracia. Nesta implementação ele pegou o
> `.claude/settings.local.json`, que não deveria estar num repositório público.

### 8.4 · Commit e publicação

```bash
git -c user.name="Seu Nome" -c user.email="seu@email.com" \
  commit -m "feat: esteira GitOps com Argo CD"

git branch -M main

gh repo create k8s-gitops-lab --public --source=. --remote=origin --push
```

**Saída:**

```
✓ Created repository mateusjacomine/k8s-gitops-lab on GitHub
✓ Added remote https://github.com/mateusjacomine/k8s-gitops-lab.git
✓ Pushed commits to https://github.com/mateusjacomine/k8s-gitops-lab.git
```

### 8.5 · Ver o pipeline rodar

```bash
gh run list --limit 3
```

```
in_progress   feat: esteira GitOps com Argo CD   CI/CD   main   push   9s
```

```bash
gh run watch
```

Ao final:

```
✓ test
✓ build
✓ update-manifest
```

### 8.6 · Confirmar que o bot commitou

```bash
git fetch origin
git log origin/main --oneline -2
```

```
38cc2d6 deploy(dev): 35d7f93 [skip ci]     ← o robô fez isso sozinho
35d7f93 feat: esteira GitOps com Argo CD
```

```bash
git show origin/main:cicd/k8s/overlays/dev/kustomization.yaml | grep newTag
```

```
    newTag: 35d7f93
```

> ✅ **Checkpoint:** a tag mudou de `dev` para o SHA do commit. O CI está
> funcionando.

---

## ETAPA 9 — Registrar as Applications

Agora o Argo CD precisa saber **qual repositório observar**.

### Comando 1 · Aplicar as duas Applications

```bash
kubectl apply -f cicd/argocd/application-dev.yaml
kubectl apply -f cicd/argocd/application-prod.yaml
```

```
application.argoproj.io/demo-api-dev created
application.argoproj.io/demo-api-prod created
```

> Se o seu repositório tiver outro nome, ajuste o `repoURL` nos arquivos antes,
> ou use o script:
> ```bash
> REPO_URL=https://github.com/SEU-USUARIO/SEU-REPO.git bash cicd/bootstrap.sh
> ```

### Comando 2 · Conferir

```bash
kubectl -n argocd get applications
```

Nos primeiros segundos as colunas ficam vazias — o Argo CD ainda está clonando:

```
NAME            SYNC STATUS   HEALTH STATUS
demo-api-dev
demo-api-prod
```

Aguarde ~40 segundos e rode de novo:

```
NAME            SYNC STATUS   HEALTH STATUS
demo-api-dev    Synced        Progressing
demo-api-prod   OutOfSync     Missing
```

> `demo-api-prod` como `OutOfSync` **está correto**. Produção espera aprovação
> manual.

### Comando 3 · Acompanhar o deploy

```bash
kubectl -n demo-dev get pods -w
```

```
NAME                        READY   STATUS    RESTARTS   AGE
demo-api-558d884996-qbhpf   1/1     Running   0          11s
```

Pressione `Ctrl+C` para sair.

---

## ETAPA 10 — Validar tudo

Rode os cinco na ordem. Todos devem bater com a saída mostrada.

### 10.1 · O Argo CD está saudável?

```bash
kubectl -n argocd get applications
```

```
NAME            SYNC STATUS   HEALTH STATUS
demo-api-dev    Synced        Healthy
demo-api-prod   OutOfSync     Missing
```

### 10.2 · A imagem correta está rodando?

```bash
kubectl -n demo-dev get deploy demo-api \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

```
ghcr.io/mateusjacomine/demo-api:7962b92
```

### 10.3 · A aplicação responde?

```bash
kubectl -n demo-dev run curl --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- curl -s http://demo-api/
```

```json
{"app":"demo-api","version":"7962b92","uptime_s":18.9}
```

> 🎯 O `version` é o **mesmo SHA** da tag da imagem e do commit. Rastreabilidade
> completa: do código em produção até a linha exata que o gerou.

### 10.4 · As métricas estão expostas?

```bash
kubectl -n demo-dev run m --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- curl -s http://demo-api/metrics | head -5
```

```
app_info{version="7962b92"} 1.0
http_requests_total{endpoint="/health",method="GET",status="200"} 5.0
http_request_duration_seconds_bucket{endpoint="/health",le="0.005"} 5.0
```

### 10.5 · O self-healing funciona?

Este é o teste definitivo do GitOps.

```bash
# O git diz: 1 réplica
kubectl -n demo-dev get deploy demo-api -o jsonpath='{.spec.replicas}'
```

```
1
```

```bash
# Sabotagem deliberada: 5 réplicas na mão
kubectl -n demo-dev scale deployment demo-api --replicas=5
kubectl -n demo-dev get deploy demo-api -o jsonpath='{.spec.replicas}'
```

```
5
```

```bash
# Espere ~10 segundos e olhe de novo
sleep 10
kubectl -n demo-dev get deploy demo-api -o jsonpath='{.spec.replicas}'
```

```
1
```

> ✅ **Voltou sozinho em ~5 segundos.** O Argo CD detectou a divergência e
> reverteu para o que está no Git. Alteração manual não sobrevive.

---

## Fluxo do dia a dia

Depois de tudo montado, **este é o único fluxo que você usa:**

```bash
# 1. Mude o código
vim cicd/app/main.py

# 2. Teste local (opcional, mas evita pipeline vermelho)
cd cicd/app && /opt/venv-cicd/bin/python -m pytest -q; cd -

# 3. Commit e push
git add -A
git commit -m "feat: nova funcionalidade"
git push

# 4. Acompanhe
gh run watch                              # o CI
kubectl -n demo-dev get pods -w           # o deploy
```

**Não existe `kubectl apply` no fluxo de deploy.** Se você aplicar algo na mão,
o `selfHeal` desfaz.

### Promover para produção

```bash
# 1. Copie a tag validada em dev para o overlay de prod
vim cicd/k8s/overlays/prod/kustomization.yaml
git add -A && git commit -m "promote(prod): 7962b92" && git push

# 2. Aprove o sync (a decisão humana)
kubectl -n argocd patch app demo-api-prod --type merge \
  -p '{"operation":{"sync":{"revision":"main"}}}'

# 3. Verifique
kubectl -n demo-prod get pods
```

### Desfazer um deploy ruim

```bash
git revert HEAD
git push
```

O CI reconstrói a versão anterior, o Argo CD reconcilia. Rollback com autor,
data e motivo registrados.

---

## Quando dá errado

### ETAPA 6: os pods do Argo CD não ficam `Running`

```bash
kubectl -n argocd get pods
kubectl -n argocd describe pod <nome-do-pod> | tail -20
```

Causas frequentes:

| Sintoma nos Events | Causa | Solução |
|---|---|---|
| `Insufficient memory` | Cluster sem recursos | Libere recursos ou aumente as VMs |
| `ImagePullBackOff` | Sem acesso à internet | Verifique DNS e saída do cluster |
| `Pending` sem eventos | Nenhum nó elegível | `kubectl get nodes` |

### ETAPA 9: `SYNC STATUS` fica vazio

O Argo CD ainda está clonando o repositório. Espere 40 segundos.

Se persistir:

```bash
kubectl -n argocd describe app demo-api-dev | tail -20
```

Procure por erro de acesso ao repositório — geralmente `repoURL` errado.

### ETAPA 10: o pod fica em `ImagePullBackOff`

```bash
kubectl -n demo-dev describe pod <nome> | grep -A5 Events
```

```
Failed to pull image "ghcr.io/...": 403 Forbidden
```

**Causa:** o package do GHCR nasce **privado**.

**Solução:** acesse `https://github.com/users/SEU-USUARIO/packages/container/demo-api/settings`
e mude a visibilidade para **Public**.

**Conferir:**

```bash
gh api user/packages/container/demo-api --jq '.visibility'
```

```
public
```

### ETAPA 10: o pod fica em `CrashLoopBackOff`

Este erro **aconteceu de verdade** nesta implementação. O método de diagnóstico:

```bash
# 1. Qual o exit code?
kubectl -n demo-dev describe pod <nome> | grep -A5 'Last State'
```

```
Last State:     Terminated
  Reason:       Error
  Exit Code:    1
```

| Exit Code | Significado |
|---|---|
| **1** | Erro da aplicação |
| **137** | 128+9 SIGKILL → OOMKilled (falta de memória) |
| **143** | 128+15 SIGTERM → encerramento normal |

```bash
# 2. O que a aplicação disse antes de morrer?
kubectl -n demo-dev logs <nome> --previous
```

> 📌 **`--previous` é obrigatório aqui.** Sem ele você pede o log do container
> atual — que pode nem existir, porque morreu.

**O erro que apareceu:**

```
File "/app/main.py", line 61, in <module>
    app = FastAPI(title="demo-api", version=VERSION, lifespan=lifespan)
AssertionError: A version must be provided for OpenAPI, e.g.: '2.1.0'
```

**Causa raiz:** o manifesto usava `fieldRef` de um label:

```yaml
env:
  - name: APP_VERSION
    valueFrom:
      fieldRef:
        fieldPath: metadata.labels['app.kubernetes.io/version']
```

Labels aplicados com `includeSelectors: false` **não chegam ao pod template** —
a variável chegava vazia.

E o código não protegia:

```python
os.getenv("APP_VERSION", "dev")
```

O default do `os.getenv` só age quando a variável **não existe**. Variável
existente e vazia devolve `""`:

```python
os.getenv("NAO_EXISTE", "dev")   # → "dev"
os.getenv("EXISTE_VAZIA", "dev") # → ""
```

**Correção — as duas camadas:**

```python
VERSION = os.getenv("APP_VERSION") or "dev"
```

```yaml
env:
  - name: APP_VERSION
    value: "7962b92"     # valor literal, atualizado pelo CI
```

### Pipeline falha no job `build`

```bash
gh run view --log-failed
```

| Erro | Causa | Solução |
|---|---|---|
| `denied: permission_denied` | Falta `packages: write` | Adicione ao bloco `permissions` do job |
| `unauthorized` | Token sem escopo | `gh auth refresh -s write:packages` |

### Pipeline entra em loop infinito

Você esqueceu o `[skip ci]` na mensagem de commit do job `update-manifest`.

```bash
# Pare as execuções
gh run list --limit 20 --json databaseId --jq '.[].databaseId' | \
  xargs -I{} gh run cancel {}
```

Depois corrija o workflow.

### `git push` rejeitado com `non-fast-forward`

O bot do CI commitou antes de você.

```bash
git pull --rebase origin main
git push origin main
```

---

## Resumo — todos os comandos em sequência

```bash
# ── Preparação ──
mkdir -p cicd/app cicd/k8s/base cicd/k8s/overlays/{dev,prod} cicd/argocd .github/workflows

# ── Etapas 1-5: criar os arquivos (ver seções acima) ──

# ── Etapa 2: validar a aplicação ──
python3 -m venv /opt/venv-cicd
/opt/venv-cicd/bin/pip install -q -r cicd/app/requirements.txt pytest httpx
cd cicd/app && /opt/venv-cicd/bin/python -m pytest -q; cd -

# ── Etapa 5: validar os manifestos ──
kubectl kustomize cicd/k8s/overlays/dev | kubectl apply --dry-run=server -f -

# ── Etapa 6: instalar o Argo CD ──
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=600s
kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"targetPort":8080,"nodePort":30443}]}}'
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# ── Etapa 8: publicar ──
git init && git add -A
git grep -nIE "(password|senha|token|secret)[\"' ]*[:=]" -- $(git diff --cached --name-only)
git commit -m "feat: esteira GitOps"
git branch -M main
gh repo create k8s-gitops-lab --public --source=. --remote=origin --push
gh run watch

# ── Etapa 9: registrar ──
kubectl apply -f cicd/argocd/application-dev.yaml
kubectl apply -f cicd/argocd/application-prod.yaml
kubectl -n argocd get applications

# ── Etapa 10: validar ──
kubectl -n demo-dev get pods
kubectl -n demo-dev run curl --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- curl -s http://demo-api/
kubectl -n demo-dev scale deployment demo-api --replicas=5 && sleep 10
kubectl -n demo-dev get deploy demo-api -o jsonpath='{.spec.replicas}'   # deve voltar a 1
```
