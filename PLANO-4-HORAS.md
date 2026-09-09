# Plano de 4 Horas — o que realmente cabe

> **Decisão já tomada: Python.** Não abra os arquivos de Go. Se perguntarem por
> que Python, responda: *"escolhi pela fluência; conheço os conceitos de
> concorrência em Go e posso falar sobre eles, mas escrevo mais rápido em Python."*

## Divisão do tempo

| Bloco | Tempo | O quê |
|---|---|---|
| 1 | **60 min** | Coding em Python — o único que exige prática motora |
| 2 | **70 min** | Troubleshooting no cluster (mãos no teclado) |
| 3 | **40 min** | Decoreba de alto retorno (exit codes, SLI/SLO, MTTR) |
| 4 | **30 min** | Simulado cronometrado falando alto |
| — | **40 min** | Folga: descanso, setup do ambiente, imprevisto |

**Não tente cobrir tudo.** O que ficar de fora, você responde com raciocínio.

---

# BLOCO 1 — Coding (60 min) · faça primeiro, é o de maior risco

### 1.1 · 10 min — leia o esqueleto UMA vez

[coding/ESQUELETOS.md](coding/ESQUELETOS.md), só a parte de Python (~45 linhas).

Grave a estrutura, não o texto:
```
parse_ts()          -> normaliza 'Z' para '+00:00'
loop items or []    -> metadata or {} / status or {}
soma restartCount   -> containerStatuses or []
filtra e ordena
```

### 1.2 · 25 min — escreva do zero, 2 vezes

```bash
cd coding\treino
python ex1_python.py
```

Implemente `filtrar()`. O teste diz se passou, incluindo os casos de borda.
**Depois de passar, apague o corpo da função e escreva de novo.** A segunda
vez é a que fixa.

### 1.3 · 15 min — acrescente o filtro de tempo

Exercício 2 em [coding/treino/enunciados.md](coding/treino/enunciados.md).
Só o filtro de 24h sobre o que você já escreveu.

### 1.4 · 10 min — decore estas 3 respostas

**"E se fossem 10 mil pods?"**
> *"O parsing é O(n) e o gargalo é a rede, não o processamento. Para vários
> clusters eu paralelizaria as chamadas com ThreadPoolExecutor."*

**"threading vs asyncio vs multiprocessing?"**
> *"Parsear pods é I/O-bound — o tempo é esperar o API server. Threads ou
> asyncio. multiprocessing só para CPU-bound, porque é o único jeito de escapar
> do GIL."*

**"Como testaria isso?"**
> *"Casos de borda primeiro: lista vazia, items null, pod sem containerStatuses
> — que some quando o pod está Pending — e timestamp ausente."*

---

# BLOCO 2 — Troubleshooting (70 min) · mãos no teclado

```bash
wsl -d Ubuntu-24.04
cd /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/labs
```

### 2.1 · 30 min — pods (o mais provável de cair)

```bash
bash break.sh pods
kgpw -n lab-pods          # deixe rodando numa aba
```

Para **cada** um dos 6 pods, diga em voz alta: *qual a fase → o que o evento diz
→ qual o comando seguinte*. Só depois confira em [labs/GUIA-TREINO.md](labs/GUIA-TREINO.md).

O que não pode faltar:
```bash
kgp -n lab-pods
kdp <pod> -n lab-pods                    # eventos no rodapé
k logs <pod> -n lab-pods --previous      # o comando de CrashLoop
```

```bash
bash break.sh fix-pods
```

### 2.2 · 20 min — node NotReady

```bash
bash break.sh kubelet-down
kubectl get nodes -w        # ~40s
```

**A pergunta que eles fazem:** *os pods daquele node pararam?*
> **Não.** O containerd segue vivo, os containers seguem servindo. O que parou
> foi o *reporte de estado*. `node-monitor-grace-period` = 40s até NotReady;
> após ~5min o controller começa a despejar.

```bash
ssh vagrant@192.168.172.131 'sudo journalctl -u kubelet -n 30 --no-pager'
bash break.sh fix-kubelet-down
```

### 2.3 · 20 min — rede

```bash
kubectl apply -f 03-network/network-scenarios.yaml
kubectl -n backend get endpoints
```

A distinção que vale ponto:
```
api                10.244.x.x:80    <- correto
api-porta-errada   10.244.x.x:8080  <- TEM endpoints, porta errada
api-quebrado       <none>           <- selector nao casa
```

A cadeia que o roteiro pede: **DNS → Endpoints → kube-proxy/CNI → NetworkPolicy**

Se sobrar tempo: `bash 03-network/test-netpol.sh`

---

# BLOCO 3 — Decoreba de alto retorno (40 min)

Só isto. É o que cai e tem resposta objetiva.

### Exit codes
| Code | Significa |
|---|---|
| **137** | 128+9 SIGKILL → **OOMKilled** |
| 143 | 128+15 SIGTERM → encerramento normal (drain) |
| 1 | erro da aplicação |

### Requests vs Limits
> *"Request é o que o **scheduler** usa para escolher o node. Limit é o que o
> **kernel** impõe via cgroup. Memória é incompressível: estourou o limit, o OOM
> killer manda SIGKILL. CPU é compressível: estourou, sofre throttling — fica
> lento, não morre."*

### QoS
`Guaranteed` (requests==limits) → `Burstable` → `BestEffort` (nada) = **primeiro a morrer**

### Probes
- **readiness** falha → sai dos **Endpoints** (não reinicia)
- **liveness** falha → **reinicia** o container
- **startup** → protege app de boot lento

> Ponte de ouro entre os temas: *"pod não-Ready é removido dos Endpoints do
> Service"* — liga o bloco de pods ao de rede.

### SLI / SLO / SLA
- **SLI** = a medida (*"% de requests < 300ms e sem 5xx"*)
- **SLO** = a meta interna (*"99.9% em 30 dias"*)
- **SLA** = o contrato externo com penalidade
- **SLA sempre mais frouxo que o SLO**
- **Error budget** = 100% − SLO. 99.9% em 30 dias = **43 min**

### MTTD vs MTTR
- **MTTD** = falha → detectar
- **MTTR** = falha → **recuperado**
- > *"Reduzir MTTR costuma dar mais retorno que aumentar MTBF: falhas vão
  > acontecer, o que se controla é quanto duram. O maior ganho isolado é
  > rollback rápido."*

### Os 3 pilares (caso de latência alta)
> *"**Métricas** dizem que existe e delimitam o escopo — p95 por serviço.
> **Traces** dizem onde o tempo é gasto: se o span do banco domina, é o banco;
> se os spans somam menos que o total, o tempo 'invisível' é CPU throttling.
> **Logs** dizem por quê. Confirmo throttling com
> `container_cpu_cfs_throttled_seconds_total`."*

### Drain
```bash
kubectl cordon k8s-w1
kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data
```
- `--ignore-daemonsets` porque DaemonSet é recriado no mesmo node
- **PDB** bloqueia o drain. `minAvailable: 2` com 2 réplicas → trava para sempre
- PDB **só** protege contra disrupção **voluntária**

---

# BLOCO 4 — Simulado (30 min)

1. Rode **um** cenário sem escolher qual (peça para alguém, ou sorteie)
2. **10 minutos** cronometrados para achar e corrigir
3. **Fale o tempo todo** — é metade da avaliação

Abertura que sempre funciona:
```bash
kgn                  # algum node fora?
kbad                 # pods não-Running
kev | tail -20       # o que aconteceu?
kdp <pod>            # eventos do suspeito
k logs <pod> --previous
```

---

# Se sobrar só 1 hora

Faça **apenas** isto:
1. **25 min** — exercício 1 de Python até passar
2. **20 min** — `bash break.sh pods` e diagnosticar os 6
3. **15 min** — exit code 137, requests vs limits, SLI/SLO/SLA, MTTR

---

# Na hora da entrevista

- **Pense alto sempre.** Silêncio é o pior sinal.
- **Diga o porquê antes do comando:** *"vou usar `--previous` porque em
  CrashLoop o container atual pode não existir."*
- **Não invente.** *"Não lembro a flag exata, mas o conceito é..."* pontua mais
  que chutar errado.
- **Escreva o esqueleto primeiro**, preencha depois. Assinatura → `pass` → corpo.
- Se travar: *"deixa eu simplificar — primeiro faço funcionar, depois trato os
  casos de borda."*
