# Observabilidade — Prometheus, Grafana e SLOs

Stack de monitoramento sobre o cluster, coletando as métricas que a `demo-api`
já expunha e transformando-as em SLIs, SLOs e alertas.

---

## Acesso

| Ferramenta | URL | Credenciais |
|---|---|---|
| **Grafana** | http://192.168.172.130:30300 | `admin` / `admin` |
| **Prometheus** | via port-forward (abaixo) | — |

```bash
kubectl -n monitoring port-forward --address 0.0.0.0 \
  svc/monitoring-kube-prometheus-prometheus 9090:9090
# depois: http://localhost:9090
```

---

## Instalação — 2 comandos

### Comando 1 · metrics-server

Habilita `kubectl top`. Leve (~50 Mi) e pré-requisito para HPA.

```bash
bash observability/01-metrics-server.sh
```

**Saída esperada:**

```
NAME      CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
k8s-cp1   91m          4%       1687Mi          66%
k8s-w1    67m          3%       932Mi           36%
k8s-w2    52m          2%       960Mi           37%
```

> O script adiciona `--kubelet-insecure-tls`. Sem essa flag o metrics-server
> entra em CrashLoop num cluster kubeadm de lab, porque o certificado do kubelet
> não é assinado por uma CA que ele reconheça.

### Comando 2 · Prometheus + Grafana

```bash
bash observability/02-prometheus-stack.sh
```

Leva 5–8 min na primeira vez (baixa ~10 imagens).

**Saída esperada — 7 pods:**

```
monitoring-grafana-686cdfb8-mpvms                      3/3   Running
monitoring-kube-prometheus-operator-774bcc9ddf-9s5dk   1/1   Running
monitoring-kube-state-metrics-8c9754d6-km5xc           1/1   Running
monitoring-prometheus-node-exporter-4xcp8              1/1   Running
monitoring-prometheus-node-exporter-dz4cx              1/1   Running
monitoring-prometheus-node-exporter-krbq7              1/1   Running
prometheus-monitoring-kube-prometheus-prometheus-0     2/2   Running
```

### Comando 3 · Regras de SLO

```bash
kubectl apply -f observability/alerts-slo.yaml
```

```
prometheusrule.monitoring.coreos.com/demo-api-slo created
```

---

## Dimensionamento para o lab

O chart padrão pede muito mais memória do que este cluster tem (~2.5 Gi por nó).
📄 `values-prometheus.yaml` reduz o consumo:

| Ajuste | Motivo |
|---|---|
| `alertmanager.enabled: false` | Sem rotas de notificação neste lab |
| `kubeControllerManager/Scheduler/Proxy/Etcd: false` | Componentes do kubeadm escutam em 127.0.0.1; os scrapers falhariam |
| `retention: 6h` + `retentionSize: 1GB` | Disco de 15 Gi por nó |
| `storageSpec: {}` | emptyDir — evita depender de StorageClass |
| `requests: 384Mi / limits: 768Mi` | Cabe nos workers |

**Consumo real:** ~1.2 Gi somando todos os componentes.

### O parâmetro que quase ninguém sabe

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
```

Sem isso, o Prometheus **só descobre ServiceMonitors que tenham o label do
release Helm** — e ignora silenciosamente os que você criar à mão. É a causa
mais comum de "criei o ServiceMonitor e o target não aparece".

---

## Como a aplicação é coletada

📄 `cicd/k8s/base/servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: demo-api
  labels:
    app: demo-api
spec:
  selector:
    matchLabels:
      app: demo-api        # casa com o Service
  endpoints:
    - port: http           # NOME da porta, não o número
      path: /metrics
      interval: 15s
```

O Prometheus Operator observa recursos `ServiceMonitor` e gera a configuração de
scrape automaticamente. **Você nunca edita `prometheus.yml`.**

Como o ServiceMonitor está na `base/` do Kustomize, ele é versionado no Git e
aplicado pelo Argo CD junto com o resto — a instrumentação segue o mesmo fluxo
GitOps da aplicação.

**Verificar se o target está ativo:**

```bash
PROM=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n monitoring exec "$PROM" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | grep -o '"job":"demo-api"'
```

---

## SLIs, SLOs e alertas

📄 `alerts-slo.yaml` — 3 recording rules e 5 alertas.

### Recording rules

Pré-calculam expressões caras, avaliadas a cada 30 s:

```promql
# Disponibilidade — proporção de requisições sem erro 5xx
demo_api:availability:ratio_5m =
  sum(rate(http_requests_total{status!~"5.."}[5m]))
    / sum(rate(http_requests_total[5m]))

# Latência p95
demo_api:latency_p95:5m =
  histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
```

### Alertas

| Alerta | Condição | Severidade |
|---|---|---|
| `DemoApiErrorBudgetBurnFast` | Burn rate > 14.4× o orçamento | critical |
| `DemoApiHighLatencyP95` | p95 > 500 ms por 5 min | warning |
| `DemoApiCpuThrottling` | Throttled em > 25% dos períodos | warning |
| `DemoApiPodRestarting` | > 3 restarts em 15 min | critical |
| `DemoApiNoReadyReplicas` | Zero réplicas prontas | critical |

### O princípio por trás das escolhas

**Alerte por sintoma do usuário, não por causa.**

*"CPU em 90%"* sem impacto no usuário é ruído que treina o time a ignorar
alertas. *"p95 acima de 500 ms"* é um problema real que alguém sente.

### Burn rate — a matemática

Com SLO de **99.9%** em 30 dias, o error budget é **0.1%** — ou **43 min 12 s**
de indisponibilidade.

| Burn rate | Consome o orçamento em | Ação |
|---|---|---|
| **14.4×** | 2 dias | Página imediatamente |
| 6× | 5 dias | Página |
| 1× | 30 dias (no ritmo) | Ticket |

Alertar por burn rate em vez de threshold fixo evita acordar alguém às 3h por
um pico de 30 segundos que não consome orçamento relevante.

---

## Queries úteis

### Da aplicação

```promql
# Requisições por rota
sum(http_requests_total) by (route)

# p95 por rota
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, route))

# Taxa de erro
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# Versão em execução
app_info
```

### Do cluster

```promql
# CPU throttling — a causa silenciosa de latência
rate(container_cpu_cfs_throttled_periods_total[5m])
  / rate(container_cpu_cfs_periods_total[5m])

# Memória vs limit (previsão de OOM)
container_memory_working_set_bytes{container!=""}
  / container_spec_memory_limit_bytes{container!=""} > 0.9

# Pods em CrashLoop
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1

# Nodes NotReady
kube_node_status_condition{condition="Ready",status="true"} == 0

# Restarts (liga com o exercício de coding)
sum by (namespace, pod) (kube_pod_container_status_restarts_total) > 5
```

---

## Validado neste cluster

| Verificação | Resultado |
|---|---|
| metrics-server | ✅ `kubectl top` funcionando |
| Stack instalado | ✅ 7 pods `Running` |
| Target da app | ✅ `health=up`, scrape a cada 15 s |
| Métricas por rota | ✅ `/health`, `/ready`, `/work`, `/metrics` separados |
| p95 medido | ✅ `/health` 4.8 ms · `/work` 72.2 ms |
| Disponibilidade | ✅ 100.000% |
| Recording rules | ✅ 3 calculando |
| Alertas | ✅ 5 carregados, todos `inactive` |

---

## Bug encontrado: colisão do label `endpoint`

### Sintoma

Todas as rotas apareciam agrupadas num único valor:

```
sum(http_requests_total) by (endpoint)
  http    10059          ← deveria separar /health, /work, /
```

### Causa raiz

O Prometheus Operator **injeta automaticamente** um label `endpoint` contendo o
**nome da porta do Service** (`http`). A aplicação usava o mesmo nome de label
para a rota HTTP. Na colisão, o label do Operator vence e sobrescreve o da
aplicação.

Consequência: impossível medir latência ou taxa de erro por rota — exatamente o
que se quer observar.

### Tentativa que não funcionou

```yaml
endpoints:
  - port: http
    honorLabels: true      # não resolve
```

O `honorLabels` atua na ingestão, mas o Operator aplica o relabel **depois**.

### Correção

Renomear o label na aplicação:

```python
# Label 'route' e nao 'endpoint': o Prometheus Operator injeta um label
# 'endpoint' com o nome da porta do Service, sobrescrevendo o nosso.
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds", "...",
    ["method", "route"],
)
```

**Resultado:**

```
sum(http_requests_total) by (route)
  /health     30
  /ready      10
  /work       25
  /metrics     2
```

### Teste de regressão

```python
def test_label_route_e_nao_endpoint():
    client.get("/health")
    corpo = client.get("/metrics").text
    assert 'route="/health"' in corpo
    assert 'endpoint="/health"' not in corpo
```

> **A lição:** labels de métrica vivem num namespace compartilhado com o que a
> plataforma injeta. Nomes genéricos (`endpoint`, `instance`, `job`, `service`,
> `pod`, `namespace`) são reservados na prática — a colisão é silenciosa e só
> aparece quando a query devolve dados agregados errados.

---

## Demonstrações

### Ver latência p95 subir em tempo real

```bash
# Aba 1 — gerar carga lenta
kubectl -n demo-dev run load --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- \
  sh -c 'while true; do curl -s -o /dev/null "http://demo-api/work?ms=800"; done'

# Aba 2 — Grafana → Explore → cole a query
# histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])) by (le, route))
```

Após ~5 min o alerta `DemoApiHighLatencyP95` passa para `firing`.

### Ver um alerta disparar

```bash
kubectl -n demo-dev scale deployment demo-api --replicas=0
# O Argo CD reverte em ~5s (selfHeal), então para testar de verdade:
kubectl -n argocd patch app demo-api-dev --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
kubectl -n demo-dev scale deployment demo-api --replicas=0
```

Após 2 min, `DemoApiNoReadyReplicas` fica `firing`.

**Restaurar:**

```bash
kubectl -n argocd patch app demo-api-dev --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}'
```

### Demonstrar CPU throttling

```bash
kubectl apply -f ../labs/04-observability/throttling-demo.yaml
sleep 60
kubectl exec throttled -- cat /sys/fs/cgroup/cpu.stat
```

```promql
rate(container_cpu_cfs_throttled_periods_total{pod="throttled"}[5m])
  / rate(container_cpu_cfs_periods_total{pod="throttled"}[5m])
```

> **A frase que fecha o assunto numa entrevista:** *"o container não tem erro,
> não reiniciou e o log está limpo — mas está congelado a maior parte do tempo.
> Só a métrica de throttling mostra isso. É por isso que métricas e logs não se
> substituem."*

---

## Dashboards no Grafana

O chart já traz dashboards prontos. Acesse **Dashboards → Browse**:

| Dashboard | Mostra |
|---|---|
| Kubernetes / Compute Resources / Namespace (Pods) | CPU e memória por pod |
| Kubernetes / Compute Resources / Node (Pods) | Recursos por nó |
| Node Exporter / Nodes | Disco, rede, load do sistema |
| Kubernetes / Kubelet | Saúde do kubelet |

Para a `demo-api`, use **Explore** com as queries da seção anterior.

---

## Troubleshooting

### O target não aparece no Prometheus

```bash
kubectl get servicemonitor -A
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'
```

Se o selector não for `{}`, o Prometheus está filtrando por label. Confirme que
`serviceMonitorSelectorNilUsesHelmValues: false` está no values.

### As métricas somem depois de um restart

Esperado: `storageSpec: {}` usa emptyDir. Para persistir, configure uma
StorageClass e um `volumeClaimTemplate`.

### O Prometheus fica em `Pending`

```bash
kubectl -n monitoring describe pod prometheus-monitoring-kube-prometheus-prometheus-0 | tail -20
```

Provável falta de memória. Reduza `prometheus.prometheusSpec.resources.requests`.

### Grafana pede senha e `admin/admin` não funciona

```bash
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```
