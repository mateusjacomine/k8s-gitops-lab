# Runbook — Observabilidade, SRE e Métricas de Confiabilidade

## Os Três Pilares aplicados a um caso real

O roteiro pede exatamente isto: **"alta latência na aplicação"** — distinguir
latência da app vs. gargalo de banco vs. CPU throttling. Responda assim:

### Cada pilar responde a uma pergunta diferente

| Pilar | Pergunta | Ferramenta |
|---|---|---|
| **Métricas** | *O quê* e *quando*? | Prometheus — agregado, barato, séries temporais |
| **Traces** | *Onde* no caminho da requisição? | Jaeger/Tempo — uma requisição ponta a ponta |
| **Logs** | *Por quê*? | Loki/ELK — detalhe do evento específico |

### O fluxo de investigação (narre nesta ordem)

**1. Métricas dizem que existe um problema e delimitam o escopo**

```promql
# p95 de latencia HTTP por serviço
histogram_quantile(0.95,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))
```

Aqui já se separa: é *um* serviço ou *todos*? Se todos → infra (rede, node,
DNS). Se um → aquele serviço ou suas dependências.

**2. Traces dizem ONDE o tempo é gasto**

Abra um trace lento e olhe a repartição dos spans:
- Span do banco com 800ms de 900ms → **gargalo de banco**.
- Spans somam 200ms mas o total é 900ms → **700ms "invisíveis"**: fila de
  runtime, GC, ou **CPU throttling**.

Esse "tempo que não aparece em span nenhum" é o sinal clássico de throttling.

**3. Métricas de infra confirmam a hipótese de throttling**

```promql
# A metrica que o roteiro cita explicitamente
rate(container_cpu_cfs_throttled_seconds_total[5m])

# Fracao de periodos em que houve throttle (>0.25 ja e problema serio)
rate(container_cpu_cfs_throttled_periods_total[5m])
  / rate(container_cpu_cfs_periods_total[5m])
```

**Como explicar o mecanismo:** o CFS do kernel divide o tempo em períodos de
100ms. Um limit de `500m` dá 50ms de CPU por período. Um pico que precise de
80ms é **congelado por 20ms** até o próximo período — a aplicação fica lenta sem
nenhum erro, sem OOM, sem log. É por isso que só as métricas revelam.

**4. Logs explicam o porquê pontual**

```bash
kubectl logs -l app=api --since=15m | grep -i -E 'timeout|slow query|deadlock'
```

### Distinguindo as três causas

| Sintoma | Diagnóstico |
|---|---|
| p99 alto, p50 normal | Cauda: GC, contenção de lock, cache miss |
| p50 **e** p99 altos | Saturação sistêmica ou dependência lenta |
| Traces mostram span de DB dominante | Gargalo de banco (índice, lock, pool esgotado) |
| Latência alta + `cfs_throttled` alto | **CPU throttling** — limit apertado demais |
| Latência alta + memória perto do limit | GC pressure antes do OOM |

---

## SLI, SLO, SLA, Error Budget

Definições exatas — **não confunda, é eliminatório**:

- **SLI** (*Indicator*) — a **medida**. Um número.
  *"Proporção de requisições HTTP com status != 5xx e latência < 300ms."*

```promql
sum(rate(http_requests_total{code!~"5.."}[30d]))
  / sum(rate(http_requests_total[30d]))
```

- **SLO** (*Objective*) — a **meta interna** sobre o SLI.
  *"99.9% ao longo de 30 dias."* Sem consequência contratual.

- **SLA** (*Agreement*) — o **contrato externo** com penalidade.
  *"99.5%, ou devolvemos 10% da fatura."*

> **Regra prática:** SLA sempre **mais frouxo** que o SLO. O SLO é o alarme
> interno que dispara *antes* de você quebrar o contrato.

### Error Budget

`Error budget = 100% - SLO`. Com SLO de 99.9% em 30 dias:
**43min 12s** de indisponibilidade permitida.

É o que transforma confiabilidade em decisão de engenharia:
- **Budget sobrando** → pode arriscar: deploys mais frequentes, features novas.
- **Budget estourado** → congela features, o time foca em estabilidade.

**Burn rate** — o alerta que realmente importa (multi-window, do Google SRE):

| Burn rate | Consome o budget em | Janela de alerta | Severidade |
|---|---|---|---|
| 14.4x | 2 dias | 1h e 5min | Página imediatamente |
| 6x | 5 dias | 6h e 30min | Página |
| 1x | 30 dias (no ritmo) | 3d e 6h | Ticket |

Alertar por burn rate em vez de threshold fixo evita o ruído de "CPU > 80%" que
não afeta usuário nenhum.

---

## MTTD, MTTR e afins

| Sigla | Nome | O que mede |
|---|---|---|
| **MTTD** | Mean Time To **Detect** | Falha começa → alguém/algo percebe |
| **MTTA** | Mean Time To **Acknowledge** | Alerta dispara → engenheiro assume |
| **MTTR** | Mean Time To **Recovery** | Falha começa → serviço restaurado |
| **MTBF** | Mean Time Between Failures | Intervalo entre incidentes |

**Como reduzir cada um** (a pergunta de follow-up provável):

- **MTTD** ↓ → alertas baseados em **sintoma do usuário** (SLI), não em causa
  (CPU). Health checks e synthetic monitoring.
- **MTTA** ↓ → on-call bem definido, escalonamento automático, runbook no alerta.
- **MTTR** ↓ → **rollback rápido** (o maior ganho isolado), feature flags,
  runbooks testados, dashboards prontos antes do incidente.

> Ponto forte para dizer: *"reduzir MTTR normalmente dá mais retorno que aumentar
> MTBF — falhas vão acontecer; o que se controla é quanto tempo elas duram."*

---

## Instalando a stack no lab

```bash
# metrics-server (habilita kubectl top) - lab sem TLS valido precisa da flag
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl top nodes
kubectl top pods -A --sort-by=memory
```

```bash
# kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.retention=2d \
  --set prometheus.prometheusSpec.resources.limits.memory=1Gi

# Acesso (do Windows: --address 0.0.0.0 e abrir http://192.168.172.130:3000)
kubectl -n monitoring port-forward --address 0.0.0.0 svc/monitoring-grafana 3000:80
```

### Queries para praticar

```promql
# Pods reiniciando (liga com o exercicio de coding)
sum by (namespace, pod) (kube_pod_container_status_restarts_total) > 5

# Pods em CrashLoop agora
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1

# CPU throttling - a metrica do roteiro
rate(container_cpu_cfs_throttled_seconds_total{container!=""}[5m])

# Memoria usada vs limit (previsao de OOM)
container_memory_working_set_bytes{container!=""}
  / container_spec_memory_limit_bytes{container!=""} > 0.9

# Nodes NotReady
kube_node_status_condition{condition="Ready",status="true"} == 0

# Saturacao de CPU do node
1 - rate(node_cpu_seconds_total{mode="idle"}[5m])
```

---

## Demonstrando CPU throttling no lab

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: throttled
  namespace: default
spec:
  containers:
    - name: burner
      image: polinux/stress
      command: ["stress", "--cpu", "2"]   # quer 2 CPUs inteiras
      resources:
        limits:
          cpu: "200m"                      # so recebe 0.2 -> throttle severo
```

```bash
kubectl apply -f throttled.yaml
kubectl exec throttled -- cat /sys/fs/cgroup/cpu.stat
# throttled_usec sobe sem parar; nr_throttled cresce a cada periodo
```

**A frase que fecha o assunto:** *"o container não está com erro, não reiniciou e
o log está limpo — mas está congelado 60% do tempo. Só a métrica de throttling
mostra isso, e é por isso que métricas e logs não se substituem."*
