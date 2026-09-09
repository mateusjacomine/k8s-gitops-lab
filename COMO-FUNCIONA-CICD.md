# Como a Esteira de CI/CD Funciona — explicado do zero

> Este documento explica **tudo** que foi construído, sem assumir que você já
> sabe o que é Docker, Kubernetes ou GitOps. Se você entende o que é um arquivo
> e o que é a internet, consegue acompanhar.

---

## Índice

1. [A analogia da fábrica de bolos](#1-a-analogia-da-fábrica-de-bolos)
2. [Os personagens da história](#2-os-personagens-da-história)
3. [O que construímos, em uma imagem](#3-o-que-construímos-em-uma-imagem)
4. [Passo 1 — O bolo (a aplicação)](#4-passo-1--o-bolo-a-aplicação)
5. [Passo 2 — A receita da forma (Dockerfile)](#5-passo-2--a-receita-da-forma-dockerfile)
6. [Passo 3 — As instruções de montagem (Kubernetes)](#6-passo-3--as-instruções-de-montagem-kubernetes)
7. [Passo 4 — Dois ambientes com a mesma receita (Kustomize)](#7-passo-4--dois-ambientes-com-a-mesma-receita-kustomize)
8. [Passo 5 — O robô que testa e embala (GitHub Actions)](#8-passo-5--o-robô-que-testa-e-embala-github-actions)
9. [Passo 6 — O robô que entrega (Argo CD)](#9-passo-6--o-robô-que-entrega-argo-cd)
10. [O dia em que quebrou (bug real)](#10-o-dia-em-que-quebrou-bug-real)
11. [Demonstrações que provam que funciona](#11-demonstrações-que-provam-que-funciona)
12. [Todos os comandos, em ordem](#12-todos-os-comandos-em-ordem)
13. [Glossário](#13-glossário)

---

## 1. A analogia da fábrica de bolos

Imagine que você faz bolos e vende para uma loja.

**Do jeito antigo (sem CI/CD):**

Você assa o bolo em casa, coloca numa caixa, pega o ônibus, entrega na loja e
arruma na prateleira você mesmo. Toda vez. Se errar o açúcar, só descobre quando
o cliente reclama. Se quiser voltar à receita antiga, precisa lembrar qual era.

**Do jeito novo (com CI/CD):**

Você só **muda a receita no caderno**. A partir daí:

1. Um robô **prova o bolo** antes de qualquer coisa (testes)
2. Outro robô **assa e embala** (build da imagem)
3. Um terceiro robô **anota no caderno** qual embalagem é a nova (commit da tag)
4. Um robô que **mora na loja** olha o caderno sozinho e troca a prateleira

Você nunca mais vai à loja. E se o bolo novo for ruim, você **risca a última
linha do caderno** e o robô da loja volta a receita anterior sozinho.

> **CI** = Continuous Integration = os robôs que testam e assam
> **CD** = Continuous Delivery = os robôs que entregam

---

## 2. Os personagens da história

| Personagem | Nome real | O que faz |
|---|---|---|
| 📓 O caderno de receitas | **Git / GitHub** | Guarda tudo e lembra de cada mudança |
| 🍰 O bolo | **A aplicação** (`main.py`) | O programa que atende as pessoas |
| 📦 A embalagem | **Imagem Docker** | O bolo + tudo que ele precisa, lacrado |
| 🏬 O depósito de embalagens | **GHCR** (registry) | Onde as embalagens ficam guardadas |
| 🏪 A loja | **Cluster Kubernetes** | Onde o bolo é servido às pessoas |
| 🤖 Robô de teste e embalagem | **GitHub Actions** | Prova, assa, embala, anota |
| 🤖 Robô da loja | **Argo CD** | Lê o caderno e arruma a prateleira |
| 📐 A régua de ajuste | **Kustomize** | Mesma receita, porções diferentes |

---

## 3. O que construímos, em uma imagem

```
   VOCÊ
    │
    │  git push  (escreve no caderno)
    ▼
┌───────────────────────────────────────────┐
│  GITHUB  (o caderno na nuvem)             │
└───────────────┬───────────────────────────┘
                │ avisa o robô
                ▼
┌───────────────────────────────────────────┐
│  GITHUB ACTIONS  (robô de fábrica)        │
│                                           │
│   1. testa    →  se falhar, PARA AQUI     │
│   2. embala   →  manda pro depósito       │
│   3. anota    →  escreve a tag no caderno │
└───────────────┬───────────────────────────┘
                │
                │  (o robô de fábrica NUNCA entra na loja)
                ▼
┌───────────────────────────────────────────┐
│  GITHUB  (caderno atualizado)             │
└───────────────┬───────────────────────────┘
                │
                │  ⬅ o robô da loja OLHA o caderno
                │     a cada 3 minutos
                ▼
┌───────────────────────────────────────────┐
│  ARGO CD  (robô que mora na loja)         │
│  "o caderno mudou → vou arrumar"          │
└───────────────┬───────────────────────────┘
                ▼
┌───────────────────────────────────────────┐
│  CLUSTER KUBERNETES  (a loja)             │
│  troca o bolo velho pelo novo             │
│  sem fechar a loja                        │
└───────────────────────────────────────────┘
```

### 🔑 A ideia mais importante de todas

Repare na seta: **o robô de fábrica nunca entra na loja.** Ele só escreve no
caderno. Quem entra na loja é o robô que já mora lá.

Isso se chama **modelo pull** ("puxar"), e é o oposto do **modelo push**
("empurrar"), em que a fábrica teria a chave da loja.

**Por que isso importa:**

- A chave da loja **nunca sai da loja**. Se alguém invadir o GitHub, não
  consegue mexer no cluster, porque a senha não está lá.
- A loja pode ficar **atrás de um muro** (rede privada, sem endereço público) e
  ainda assim funcionar, porque é ela que sai para olhar o caderno.
- O caderno é a **única verdade**. Se alguém mexer na prateleira à mão, o robô
  desfaz.

---

## 4. Passo 1 — O bolo (a aplicação)

Escrevemos um programa em Python que responde perguntas pela internet.

📄 **`cicd/app/main.py`**

Ele tem quatro "portas" (chamadas de *endpoints*):

| Porta | Para que serve | Analogia |
|---|---|---|
| `/health` | "Você está vivo?" | Cutucar para ver se acorda |
| `/ready` | "Pode atender clientes?" | Já vestiu o uniforme? |
| `/metrics` | Números sobre o funcionamento | O relógio de ponto da loja |
| `/work` | Faz um trabalho que demora um pouco | Assar de verdade |

### Por que `/health` e `/ready` são coisas DIFERENTES?

Essa distinção confunde muita gente adulta, então vamos com calma.

Imagine um funcionário que acabou de chegar na loja:

- **Está vivo?** Sim, ele está respirando. → `/health` responde "ok"
- **Pode atender?** Ainda não! Está vestindo o uniforme. → `/ready` responde "espera"

Se o Kubernetes só tivesse uma pergunta, ele faria uma de duas besteiras:

- Mandaria clientes para quem ainda está se vestindo (cliente mal atendido), ou
- Demitiria o funcionário por não estar pronto (mas ele só precisava de tempo)

Com as duas perguntas separadas:

- `/health` falhou → o funcionário **desmaiou**, chame outro (reinicia o container)
- `/ready` falhou → ele está vivo mas ocupado, **não mande clientes** (tira da fila)

### O trecho que faz isso

```python
# Enquanto READY for 0, o /ready devolve 503 = "ainda nao, espera"
READY = Gauge("app_ready", "1 quando a aplicacao esta pronta")
READY.set(0)

@asynccontextmanager
async def lifespan(_app: FastAPI):
    if BOOT_DELAY > 0:
        time.sleep(BOOT_DELAY)     # simula demora para vestir o uniforme
    READY.set(1)                   # AGORA sim, pronto
    yield
    READY.set(0)                   # ao desligar, sai da fila primeiro
```

### E o `/metrics`?

É um relógio de ponto que anota tudo: quantas pessoas foram atendidas, quanto
tempo cada atendimento levou, qual versão do bolo está sendo servida.

Um programa chamado **Prometheus** lê esses números e monta gráficos. Assim você
descobre coisas como *"95% dos clientes esperam menos de 80 milissegundos"*.

**Ver os números de verdade:**

```bash
kubectl -n demo-dev run m --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- curl -s http://demo-api/metrics
```

Saída real deste cluster (131 linhas, aqui um pedaço):

```
app_info{version="7962b92"} 1.0
http_requests_total{endpoint="/health",method="GET",status="200"} 5.0
http_request_duration_seconds_bucket{endpoint="/health",le="0.005"} 5.0
```

### O robô prova o bolo antes: os testes

📄 **`cicd/app/test_main.py`** — 8 testes que rodam **antes** de qualquer coisa.

```python
def test_ready_503_antes_do_startup():
    """Sem o lifespan, /ready deve recusar trafego."""
    r = client.get("/ready")
    assert r.status_code == 503
```

Se **um** teste falhar, a esteira inteira para. O bolo ruim nunca chega na loja.

**Rodar os testes:**

```bash
wsl -d Ubuntu-24.04 -u root -- bash \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/validate.sh
```

Resultado real: `8 passed`

---

## 5. Passo 2 — A receita da forma (Dockerfile)

### O problema que o Docker resolve

Você já ouviu *"mas na minha máquina funciona"*? Isso acontece porque o programa
depende de coisas que existem no seu computador e não no outro.

O Docker resolve **lacrando tudo junto**: o programa, a versão exata do Python,
todas as bibliotecas. Essa caixa lacrada chama-se **imagem**.

Ela funciona **igual** no seu notebook, no servidor e na nuvem.

📄 **`cicd/app/Dockerfile`**

```dockerfile
# ETAPA 1 — a cozinha bagunçada: instala as ferramentas
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ETAPA 2 — a embalagem limpa: só o que o cliente recebe
FROM python:3.12-slim
RUN useradd -u 10001 -m appuser      # <- NÃO roda como "dono de tudo"
WORKDIR /app
COPY --from=builder /install /usr/local
COPY main.py .
USER 10001
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Duas decisões importantes aqui

**1. Duas etapas (multi-stage)**

A primeira etapa é a cozinha suja: instala compiladores, baixa pacotes, faz
bagunça. A segunda pega **só o resultado pronto**.

É como assar na cozinha e levar só o bolo — não a cozinha inteira. A caixa fica
menor e mais segura (ferramentas de cozinha nas mãos erradas viram armas).

**2. `USER 10001` — não rodar como "root"**

`root` é o usuário que pode fazer **qualquer coisa** no sistema. Se um invasor
tomar um programa que roda como root, ele controla tudo.

Criamos um usuário comum, sem poderes. Se der problema, o estrago é pequeno.

> Isso é o que se chama **princípio do menor privilégio**: dê a cada um só o
> poder de que precisa, nada mais.

---

## 6. Passo 3 — As instruções de montagem (Kubernetes)

Agora precisamos dizer para a loja **como** servir o bolo. No Kubernetes,
isso se faz escrevendo arquivos `.yaml`.

📁 **`cicd/k8s/base/`** — três arquivos:

| Arquivo | O que declara |
|---|---|
| `deployment.yaml` | Quantas cópias do programa e como cuidar delas |
| `service.yaml` | O endereço fixo para encontrá-lo |
| `pdb.yaml` | Quantas cópias podem faltar durante uma manutenção |

### Por que um endereço fixo? (o Service)

Os programas no Kubernetes recebem endereços que **mudam** — toda vez que um
reinicia, ganha um número novo. É como um funcionário que troca de crachá todo
dia.

O **Service** é o telefone da recepção: um número que nunca muda. Você liga para
ele e a recepção passa para quem estiver disponível.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-api        # <- o nome vira o endereço: http://demo-api
spec:
  selector:
    app: demo-api       # <- "encaminhe para quem tiver esta etiqueta"
  ports:
    - port: 80
      targetPort: http
```

### Trocar o bolo sem fechar a loja

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1          # pode ter 1 a mais temporariamente
    maxUnavailable: 0    # NUNCA pode ter menos que o combinado
```

Traduzindo o `maxUnavailable: 0`: **primeiro** o funcionário novo chega e veste o
uniforme; **só depois** o antigo vai embora. Nunca fica ninguém na loja.

É por isso que o `/ready` existe — é ele que diz "o novo já vestiu o uniforme".

### As três perguntas de saúde

```yaml
startupProbe:                        # "já terminou de acordar?"
  httpGet: { path: /health, port: http }
  periodSeconds: 2
  failureThreshold: 30               # dá até 60 segundos de paciência

readinessProbe:                      # "pode atender clientes?"
  httpGet: { path: /ready, port: http }
  periodSeconds: 5

livenessProbe:                       # "ainda está vivo?"
  httpGet: { path: /health, port: http }
  periodSeconds: 10
  failureThreshold: 3
```

**Por que a `startupProbe` é separada?** Porque um programa pode demorar 40
segundos para acordar, mas depois responder em 1 segundo.

Sem ela você teria que escolher entre dois erros:
- Paciência curta → mata o programa durante o boot, para sempre (loop infinito)
- Paciência longa → demora demais para perceber travamentos de verdade

Com ela: **muita paciência no começo, pouca paciência depois**. É a resposta
certa.

### O bilhete de "não leve todos ao mesmo tempo" (PDB)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  maxUnavailable: 1     # no máximo 1 cópia fora por vez
```

Quando um servidor precisa de manutenção, o Kubernetes tira os programas dele.
O PDB é o bilhete: *"pode tirar, mas nunca mais de 1 por vez."*

> ⚠️ **A armadilha clássica:** escrever `minAvailable: 2` quando você tem
> exatamente 2 cópias. Isso significa "nunca tire nenhuma" — e a manutenção
> **trava para sempre**. Por isso usamos `maxUnavailable`, que se ajusta sozinho
> ao número de cópias.

---

## 7. Passo 4 — Dois ambientes com a mesma receita (Kustomize)

Queremos dois lugares:

- **dev** = a cozinha de testes. 1 cópia. Pode quebrar à vontade.
- **prod** = a loja de verdade. 2 cópias. Não pode quebrar.

A receita é a mesma. Só mudam as porções.

Copiar tudo em dois arquivos seria péssimo: você corrige um bug num lugar e
esquece do outro. O **Kustomize** resolve isso com "receita base + ajustes".

```
cicd/k8s/
├── base/                  ← a receita, escrita UMA vez
│   ├── deployment.yaml
│   ├── service.yaml
│   └── pdb.yaml
└── overlays/
    ├── dev/               ← "igual à base, mas 1 cópia"
    └── prod/              ← "igual à base, mas 2 cópias e mais CPU"
```

📄 **`cicd/k8s/overlays/dev/kustomization.yaml`**

```yaml
resources:
  - ../../base            # <- puxa a receita inteira

images:
  - name: ghcr.io/mateusjacomine/demo-api
    newTag: 7962b92       # <- ESTA LINHA é o gatilho do deploy

replicas:
  - name: demo-api
    count: 1
```

> 📌 **Guarde esta linha.** O `newTag` é o coração de tudo. Quando o robô de
> fábrica muda esse número, o robô da loja vê a mudança e troca o programa.
> **Um deploy é literalmente a troca de uma linha de texto num arquivo.**

**Ver a receita final montada:**

```bash
wsl -d Ubuntu-24.04 -u root -- kubectl kustomize \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/k8s/overlays/dev
```

### Por que a tag é `7962b92` e não `latest`?

`7962b92` é o código do commit — como o número de série de um lote de fábrica.

Muita gente usa `latest` ("a mais nova"). É uma péssima ideia:

| | `latest` | `7962b92` |
|---|---|---|
| Qual versão está rodando? | Ninguém sabe | Exatamente esse commit |
| Voltar atrás | Impossível, foi sobrescrita | É só apontar para a anterior |
| Dois servidores iguais? | Podem ter versões diferentes | Sempre idênticos |

> `latest` é como escrever "o bolo de hoje" na embalagem. Amanhã, ninguém sabe
> qual bolo era.

---

## 8. Passo 5 — O robô que testa e embala (GitHub Actions)

📄 **`.github/workflows/ci-cd.yaml`**

Este é o robô da fábrica. Ele acorda sozinho toda vez que você escreve no
caderno, e faz **três tarefas em sequência**.

### Tarefa 1 — Provar o bolo

```yaml
test:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4          # pega o código
    - uses: actions/setup-python@v5      # instala Python
    - name: Testes
      working-directory: cicd/app
      run: pytest -q                     # PROVA o bolo
```

Se um teste falhar, **acabou**. As tarefas seguintes nem começam.

### Tarefa 2 — Assar e embalar

```yaml
build:
  needs: test                            # <- só roda se os testes passaram
  steps:
    - name: Definir tag imutavel
      run: echo "short_sha=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"

    - name: Build e push
      uses: docker/build-push-action@v6
      with:
        context: cicd/app
        push: true
        tags: |
          ghcr.io/.../demo-api:${{ steps.meta.outputs.short_sha }}
```

O `needs: test` é o cadeado: nada é embalado sem antes ser provado.

### Tarefa 3 — Anotar no caderno

Esta é a tarefa mais interessante — e a mais sutil.

```yaml
update-manifest:
  needs: build
  steps:
    - name: Atualizar tag da imagem
      working-directory: cicd/k8s/overlays/dev
      run: |
        TAG="${{ needs.build.outputs.image_tag }}"
        sed -i "s|newTag: .*|newTag: ${TAG}|" kustomization.yaml

    - name: Commit
      run: |
        git commit -m "deploy(dev): ${TAG} [skip ci]"
        git push
```

O robô **escreve no caderno** e vai embora. Ele não liga para a loja, não tem a
chave da loja, não sabe nem onde a loja fica.

> **`[skip ci]`** na mensagem é importante: sem isso, esse commit acordaria o
> robô de novo, que faria outro commit, que o acordaria de novo... para sempre.
> Esse aviso quebra o ciclo.

### O resultado real

```bash
gh run list --limit 3
```

```
completed  success  fix(app): APP_VERSION vazia...  CI/CD  main  push  57s
completed  success  docs(cicd): README da esteira   CI/CD  main  push  1m24s
```

E o commit que o robô fez sozinho:

```
9996db7 deploy(dev): 7962b92 [skip ci]
```

---

## 9. Passo 6 — O robô que entrega (Argo CD)

### Instalando o robô na loja

```bash
wsl -d Ubuntu-24.04 -u root -- bash \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/argocd/install.sh
```

Resultado: 7 programas do Argo CD rodando dentro do cluster.

### Dando as instruções ao robô

📄 **`cicd/argocd/application-dev.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-api-dev
spec:
  source:
    repoURL: https://github.com/mateusjacomine/k8s-gitops-lab.git
    targetRevision: main
    path: cicd/k8s/overlays/dev      # <- "olhe ESTA gaveta do caderno"
  destination:
    namespace: demo-dev              # <- "arrume ESTA prateleira"
  syncPolicy:
    automated:
      prune: true                    # tirou do caderno? tire da prateleira
      selfHeal: true                 # mexeram na prateleira? desfaça
```

Lendo em português: *"Robô, olhe a gaveta `overlays/dev` do caderno. A prateleira
`demo-dev` deve ficar exatamente igual ao que está escrito lá. Se alguém mexer,
desfaça."*

**Registrar:**

```bash
wsl -d Ubuntu-24.04 -u root -- bash \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/bootstrap.sh
```

### As duas palavras mágicas

**`selfHeal: true`** — "cura sozinho"

Se alguém mexer na prateleira à mão, o robô desfaz. Isso acaba com o problema
do *"quem foi que mexeu no servidor?"*, porque não adianta mexer — volta.

**`prune: true`** — "poda"

Se você apagar algo do caderno, o robô apaga da prateleira também. Sem isso,
lixo se acumularia para sempre.

### Por que produção é diferente

📄 **`cicd/argocd/application-prod.yaml`** — repare no que **não** tem:

```yaml
  syncPolicy:
    # SEM 'automated': producao exige sync manual.
    syncOptions:
      - CreateNamespace=true
```

Em dev, tudo é automático. Em produção, **uma pessoa precisa apertar o botão**.

Por quê? Porque colocar algo em produção é uma **decisão**, não uma consequência
de ter escrito código. Primeiro você olha se o bolo ficou bom em dev, depois
decide servi-lo aos clientes de verdade.

```bash
# Ver o estado dos dois
kubectl -n argocd get applications
```

```
NAME            SYNC STATUS   HEALTH STATUS
demo-api-dev    Synced        Healthy       ← automático, tudo certo
demo-api-prod   OutOfSync     Missing       ← esperando alguém decidir
```

> `OutOfSync` em prod **não é erro**. É o desenho funcionando.

---

## 10. O dia em que quebrou (bug real)

Isto aconteceu de verdade durante a construção. É a parte mais instrutiva.

### O sintoma

O primeiro deploy não subiu:

```bash
kubectl -n demo-dev get pods
```

```
NAME                        READY   STATUS             RESTARTS
demo-api-6dcd7fcc66-hfttc   0/1     CrashLoopBackOff   3
```

`CrashLoopBackOff` significa: *"o programa liga, morre, liga de novo, morre de
novo — e o Kubernetes está esperando cada vez mais entre as tentativas."*

### A investigação

Regra de ouro: **não adivinhe, leia o log**.

```bash
kubectl -n demo-dev logs <nome-do-pod> --previous
```

> 📌 O `--previous` é essencial. Sem ele você pede o log do programa **atual** —
> que talvez nem exista, porque morreu. Com ele, você lê as últimas palavras da
> tentativa anterior.

A resposta estava lá:

```
File "/app/main.py", line 61, in <module>
    app = FastAPI(title="demo-api", version=VERSION, lifespan=lifespan)
AssertionError: A version must be provided for OpenAPI, e.g.: '2.1.0'
```

### A causa raiz

O programa esperava receber a versão numa variável. Estávamos passando assim:

```yaml
- name: APP_VERSION
  valueFrom:
    fieldRef:
      fieldPath: metadata.labels['app.kubernetes.io/version']
```

Traduzindo: *"pegue o valor da etiqueta `version` e coloque na variável"*.

**O problema:** o Kustomize colocava essa etiqueta com a opção
`includeSelectors: false`, e nessa configuração a etiqueta **não chega até o
programa**. A variável chegava **vazia** — e o FastAPI se recusa a ligar sem
versão.

### O detalhe que engana todo mundo

O código tinha isto:

```python
VERSION = os.getenv("APP_VERSION", "dev")
```

Parece protegido, certo? *"Se não tiver, use 'dev'"*. **Errado.**

Esse `"dev"` só é usado quando a variável **não existe**. Se ela existe e está
**vazia**, você recebe a string vazia — não o `"dev"`.

```python
os.getenv("NAO_EXISTE", "dev")   # → "dev"   ✅
os.getenv("EXISTE_VAZIA", "dev") # → ""      💥
```

> É como pedir *"me traga um copo, e se não tiver copo, traga uma caneca"* — e a
> pessoa te trazer um copo **vazio**. Ela cumpriu o combinado. O copo existe.

### A correção, em duas camadas

**1. No programa** — proteção que funciona nos dois casos:

```python
# or "dev" cobre APP_VERSION definido porem VAZIO — o default do getenv
# so age quando a variavel nao existe.
VERSION = os.getenv("APP_VERSION") or "dev"
```

**2. No manifesto** — parar de depender da etiqueta:

```yaml
- name: APP_VERSION
  value: "7962b92"     # o robô de fábrica atualiza junto com a tag
```

**3. E um teste** para nunca mais acontecer:

```python
def test_version_nunca_vazia():
    """Regressao: APP_VERSION vazia derrubava o container no boot."""
    codigo = "import os; os.environ['APP_VERSION'] = ''; import main; ..."
    r = subprocess.run([sys.executable, "-c", codigo], ...)
    assert r.returncode == 0
```

### O resultado

```
NAME                        READY   STATUS    RESTARTS   AGE
demo-api-558d884996-qbhpf   1/1     Running   0          107s
```

E o programa passou a se identificar corretamente:

```json
{"app":"demo-api","version":"7962b92","uptime_s":18.9}
```

> **A lição:** um erro de digitação em YAML derrubou a aplicação inteira, e
> nenhum teste local pegaria — só apareceu no cluster. O caminho até a resposta
> foi `get pods` → `logs --previous` → ler a mensagem. Sem chute.

---

## 11. Demonstrações que provam que funciona

### 11.1 — A cura sozinha (a mais impressionante)

Vamos "sabotar" a loja de propósito e ver o robô consertar.

```bash
# 1. O caderno diz: 1 cópia
kubectl -n demo-dev get deploy demo-api -o jsonpath='{.spec.replicas}'
# → 1

# 2. Sabotagem: mando fazer 5 cópias, à mão
kubectl -n demo-dev scale deployment demo-api --replicas=5

# 3. Assista
kubectl -n demo-dev get deploy demo-api -w
```

**Resultado real medido:** o Argo CD desfez em **~5 segundos**. Voltou para 1.

> É como arrumar a cama de um jeito diferente e o robô arrumadeira desfazer
> porque "não é assim que está no manual".
>
> **Por que isso é revolucionário?** Acaba com o que se chama *configuration
> drift* — servidores que, depois de meses de ajustes manuais, ninguém mais sabe
> como estão configurados. Aqui, o caderno é sempre a verdade.

### 11.2 — Desfazer um erro

```bash
git revert HEAD
git push
```

Só isso. O robô de fábrica embala a versão anterior, escreve no caderno, o robô
da loja troca de volta.

> Não existe "quem mexeu no servidor às 3 da manhã?". Toda mudança tem autor,
> data e motivo escritos no caderno.

### 11.3 — Trocar sem fechar a loja

```bash
# Numa aba, assista
kubectl -n demo-dev get pods -w

# Noutra, faça uma mudança e dê push
```

Você verá o programa novo aparecer, ficar pronto, e **só então** o antigo sair.
Ninguém foi mal atendido.

### 11.4 — Ver a app funcionando

```bash
kubectl -n demo-dev run curl --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- curl -s http://demo-api/
```

```json
{"app":"demo-api","version":"7962b92","uptime_s":18.9}
```

O `version` é o mesmo código do commit — dá para rastrear o que está rodando
até a linha de código exata.

---

## 12. Todos os comandos, em ordem

### Setup (uma vez só — já foi feito)

```bash
# 1. Instalar o robô da loja no cluster
wsl -d Ubuntu-24.04 -u root -- bash \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/argocd/install.sh

# 2. Publicar o caderno no GitHub
cd C:\Users\Mateus\PycharmProjects\Projeto_Entrevista
gh repo create k8s-gitops-lab --public --source=. --remote=origin --push

# 3. Dizer ao robô qual caderno olhar
wsl -d Ubuntu-24.04 -u root -- bash \
  /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/bootstrap.sh
```

### O dia a dia (o único fluxo que importa)

```bash
# 1. Mude o código
#    ... edite cicd/app/main.py ...

# 2. Escreva no caderno
git add -A
git commit -m "feat: nova funcionalidade"
git push

# 3. Assista os robôs trabalharem
gh run watch                                    # o robô de fábrica
kubectl -n argocd get app demo-api-dev -w       # o robô da loja
kubectl -n demo-dev get pods -w                 # a prateleira mudando
```

**Nunca** se digita `kubectl apply` para fazer um deploy. Deploy é `git push`.

### Diagnóstico quando algo dá errado

```bash
# O que está rodando?
kubectl -n demo-dev get pods

# Por que aquele pod está estranho?
kubectl -n demo-dev describe pod <nome>        # olhe os "Events" no final

# O que o programa disse antes de morrer?
kubectl -n demo-dev logs <nome> --previous     # --previous é essencial!

# O robô da loja está feliz?
kubectl -n argocd get applications

# O robô de fábrica trabalhou?
gh run list --limit 5
```

### Colocar em produção (decisão manual, de propósito)

```bash
# 1. Copie a tag validada em dev para o arquivo de prod, commit e push
#    ... edite cicd/k8s/overlays/prod/kustomization.yaml ...

# 2. Aperte o botão
kubectl -n argocd patch app demo-api-prod --type merge \
  -p '{"operation":{"sync":{"revision":"main"}}}'
```

### Ver o painel do robô

```
https://192.168.172.130:30443
usuário: admin
```

```bash
# Descobrir a senha
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## 13. Glossário

| Palavra | Em português claro |
|---|---|
| **CI/CD** | Robôs que testam, embalam e entregam software automaticamente |
| **Git** | O caderno que guarda tudo e lembra de cada mudança |
| **Commit** | Uma anotação no caderno, com autor, data e motivo |
| **Push** | Mandar suas anotações para o caderno compartilhado |
| **Container** | Um programa lacrado com tudo que precisa para funcionar |
| **Imagem** | A "embalagem" do container, guardada num depósito |
| **Registry / GHCR** | O depósito onde as embalagens ficam |
| **Kubernetes (k8s)** | O gerente que cuida dos programas: liga, vigia, substitui |
| **Cluster** | O conjunto de computadores onde o Kubernetes manda |
| **Pod** | Uma cópia do programa rodando |
| **Deployment** | O papel que diz quantas cópias e como cuidar delas |
| **Service** | Um endereço fixo para encontrar as cópias |
| **Namespace** | Uma prateleira separada, para não misturar dev com produção |
| **Manifesto** | Um arquivo `.yaml` descrevendo o que você quer |
| **Kustomize** | Receita base + ajustes por ambiente |
| **GitOps** | O caderno é a única verdade; o cluster se ajusta a ele |
| **Argo CD** | O robô que mora no cluster e segue o caderno |
| **Sync** | Deixar a prateleira igual ao caderno |
| **Self-heal** | Desfazer mudanças feitas fora do caderno |
| **Rollback** | Voltar para a versão anterior |
| **Probe** | Uma pergunta de saúde que o Kubernetes faz ao programa |
| **CrashLoopBackOff** | Liga, morre, liga, morre — com pausas crescentes |
| **Tag imutável** | Um número de série que nunca é reaproveitado |

---

## Resumo em cinco frases

1. Você escreve código e faz `git push`. Só isso.
2. Um robô testa; se falhar, **para** e nada é entregue.
3. Se passar, ele embala o programa e **anota a nova versão no caderno**.
4. Outro robô, que **mora no cluster**, lê o caderno e ajusta a prateleira.
5. Se alguém mexer à mão, o robô desfaz — o caderno é a única verdade.

> **A frase que resume o GitOps:** o cluster não é algo que você *modifica*; é
> algo que *converge* para o que está escrito no Git.
