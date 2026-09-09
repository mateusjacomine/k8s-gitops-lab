# Lab de Preparação — Senior Kubernetes Platform Engineer

Cluster Kubernetes real de 3 nós em VMware, com cenários de falha reproduzíveis
e exercícios de coding, cobrindo os três blocos da entrevista.

## O cluster

| Nó | IP | Papel | Acesso |
|---|---|---|---|
| `k8s-cp1` | 192.168.172.130 | control-plane | `ssh vagrant@192.168.172.130` |
| `k8s-w1` | 192.168.172.131 | worker | `ssh vagrant@192.168.172.131` |
| `k8s-w2` | 192.168.172.132 | worker | `ssh vagrant@192.168.172.132` |

Rocky Linux 9.8 · Kubernetes v1.31.14 · containerd 2.3.4 · Calico (NetworkPolicy)
· usuário `vagrant` / senha `vagrant`

`kubectl` funciona **do Windows** (`C:\Users\Mateus\bin\kubectl.exe`, já no PATH)
e **do WSL** (`wsl -d Ubuntu-24.04 -u root -- kubectl get nodes`).

```powershell
kubectl get nodes -o wide
```

## Snapshots — use sem medo

```powershell
cd infra\scripts
.\snapshot.ps1 list
.\snapshot.ps1 restore cluster-limpo    # volta as 3 VMs ao estado íntegro
```

> Restaure sempre **as três juntas**. O etcd e os certificados exigem estado
> consistente entre os nós.

## Como treinar

> **Comece por [labs/GUIA-TREINO.md](labs/GUIA-TREINO.md)** — cada cenário com o
> roteiro de diagnóstico e as respostas em blocos recolhidos, para você tentar
> primeiro e conferir depois.

Os cenários de node precisam de SSH, então rode o `break.sh` no WSL:

```bash
wsl -d Ubuntu-24.04
cd /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/labs

# Aplicar um cenário de falha
bash break.sh pods                 # pods quebrados
bash break.sh kubelet-down         # node NotReady
bash break.sh coredns-down         # DNS fora
bash break.sh disk-pressure        # DiskPressure
bash break.sh netpol               # default-deny

bash break.sh status               # visão geral
bash break.sh fix                  # restaura tudo
```

## Mapa do repositório

| Caminho | Conteúdo |
|---|---|
| [runbooks/01-pods.md](runbooks/01-pods.md) | Diagnóstico de pods, exit codes, QoS, probes |
| [runbooks/02-nodes.md](runbooks/02-nodes.md) | NotReady, conditions, drain, PDB, upgrade |
| [runbooks/03-observability-sre.md](runbooks/03-observability-sre.md) | 3 pilares, SLI/SLO/SLA, error budget, MTTR |
| [labs/01-pods/](labs/01-pods/) | 6 cenários de falha de pod |
| [labs/02-nodes/](labs/02-nodes/) | PDB que bloqueia drain |
| [labs/03-network/](labs/03-network/) | Services quebrados, NetworkPolicy |
| [labs/04-observability/](labs/04-observability/) | CPU throttling, classes de QoS |
| **[COMO-FUNCIONA-CICD.md](COMO-FUNCIONA-CICD.md)** | **A esteira explicada do zero, passo a passo** |
| **[cicd/](cicd/)** | **Esteira GitOps: FastAPI + Actions + Argo CD** |
| **[coding/ESQUELETOS.md](coding/ESQUELETOS.md)** | **O que memorizar para codar do zero (~45 e ~60 linhas)** |
| **[coding/treino/](coding/treino/)** | **Exercícios em branco com testes automáticos** |
| [coding/python/](coding/python/) | `pod_analyzer.py` — versão completa, para referência |
| [coding/go/](coding/go/) | `main.go` — versão completa, para referência |
| [coding/README.md](coding/README.md) | Perguntas prováveis e respostas |

> Os arquivos em `coding/python/` e `coding/go/` têm ~230 linhas — bons para
> estudar, **impossíveis de escrever em 25 min**. Para a prova prática use
> `ESQUELETOS.md` e treine em `coding/treino/`.

## Validado neste cluster

Todos os cenários foram executados e produziram o comportamento esperado:

- `OOMKilled` com **Exit Code 137**, `CrashLoopBackOff`, `ImagePullBackOff`
- `Pending` com mensagem completa do scheduler (taint + recursos)
- Service sem endpoints (`<none>`) vs. Service com endpoints na porta errada
- NetworkPolicy: baseline 200 → deny bloqueia tudo → allow libera só o frontend
- Go: `go vet` limpo, `-race` sem data races, cancelamento por context
- Python: todos os casos de borda (listas vazias, campos ausentes, timestamps)

## Esteira GitOps

Pipeline completo rodando: push → testes → build → GHCR → commit da tag →
Argo CD sincroniza o cluster.

```
UI do Argo CD: https://192.168.172.130:30443   (admin / veja o comando abaixo)
Repositório:   https://github.com/mateusjacomine/k8s-gitops-lab
```

Demonstração mais forte — **self-healing** (validada: reverteu em ~5s):

```bash
kubectl -n demo-dev scale deployment demo-api --replicas=5
kubectl -n demo-dev get deploy demo-api -w
```

Recupere a senha inicial com:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret   -o jsonpath='{.data.password}' | base64 -d
```

📘 **Novo por aqui?** Leia [COMO-FUNCIONA-CICD.md](COMO-FUNCIONA-CICD.md) —
explica a esteira inteira do zero, sem pressupor Docker ou Kubernetes.

Detalhes técnicos em [cicd/README.md](cicd/README.md).

## Roteiro sugerido (48h)

**Hoje**
1. Ler os 3 runbooks (~40 min)
2. Rodar cada cenário de `break.sh`, diagnosticando **antes** de olhar a resposta
3. Rodar os dois programas e explicar cada decisão em voz alta

**Amanhã**
4. Instalar a stack de observabilidade ([runbooks/03](runbooks/03-observability-sre.md))
5. Cronometrar 20 min de troubleshooting falando alto
6. Revisar SLI/SLO/SLA, MTTR/MTTD e a sequência de upgrade

## Dicas finais

1. **Pense alto** — diga *por que* está eliminando cada hipótese
2. **Seja específico** — `--previous`, exit code 137, `container_cpu_cfs_throttled_seconds_total`
3. **Conecte os temas** — pod não-Ready sai dos Endpoints do Service: liga pods e rede
