# Runbook — Troubleshooting de Pods

> Objetivo na entrevista: mostrar **método de eliminação**, não decorar comando.
> Sempre diga *por que* está rodando o comando antes de rodar.

## Fluxo geral (diga isto em voz alta)

```
1. Qual a FASE do pod?        kubectl get pod -o wide
   Pending  -> problema de SCHEDULING (recursos, taints, PVC, affinity)
   Running  -> problema de APLICACAO ou PROBE
   Waiting  -> problema de IMAGEM ou init container
   Crash    -> problema de PROCESSO (exit code manda)

2. O que os EVENTOS dizem?    kubectl describe pod <nome>
   Eventos ficam na base do describe e caducam em ~1h.

3. O que o PROCESSO disse?    kubectl logs <nome> --previous
   --previous e obrigatorio em CrashLoop: o container atual pode nem existir.

4. Qual o EXIT CODE?          describe -> Last State: Terminated
```

## Tabela de exit codes (memorize — cai muito)

| Code | Significado | Causa típica |
|------|-------------|--------------|
| 0 | Saída limpa | Container de job terminou; `restartPolicy: Always` reinicia mesmo assim |
| 1 | Erro da aplicação | Exceção não tratada, config inválida |
| 137 | **SIGKILL** (128+9) | **OOMKilled** ou `kubectl delete` sem graceful shutdown |
| 143 | SIGTERM (128+15) | Encerramento normal durante drain/rollout |
| 139 | SIGSEGV (128+11) | Segfault — bug de memória no binário |
| 255 | Erro genérico | Entrypoint falhou |

---

## Cenário 1 — CrashLoopBackOff

```bash
kubectl -n lab-pods get pod crashloop
kubectl -n lab-pods logs crashloop --previous        # <<< o comando-chave
kubectl -n lab-pods describe pod crashloop | sed -n '/Last State/,/Ready/p'
```

**O que dizer:** "CrashLoopBackOff não é a causa, é o *sintoma* — o kubelet está
aplicando backoff exponencial (10s, 20s, 40s… até 5min) entre reinícios. A causa
está no log da encarnação anterior, por isso `--previous`."

## Cenário 2 — OOMKilled

```bash
kubectl -n lab-pods describe pod oomkilled | grep -A5 'Last State'
# Reason: OOMKilled, Exit Code: 137
```

**Requests vs Limits — a explicação que eles querem ouvir:**

- **Request** = o que o *scheduler* usa para escolher o node. Reserva lógica.
- **Limit** = o que o *kernel* impõe via cgroup (`memory.max` no cgroup v2).
- Memória é **incompressível**: estourou o limit → o OOM killer do kernel manda
  SIGKILL. Não há throttling possível.
- CPU é **compressível**: estourou o limit → sofre *throttling* (CFS quota),
  o processo fica lento mas não morre. Métrica:
  `container_cpu_cfs_throttled_seconds_total`.

**QoS classes** (aparece em `describe`):
- `Guaranteed`: requests == limits em todos os containers → último a ser despejado.
- `Burstable`: requests < limits.
- `BestEffort`: sem requests nem limits → **primeiro a morrer** sob pressão.

## Cenário 3 — Pending

```bash
kubectl -n lab-pods describe pod pending-recursos | tail -15
# Events: FailedScheduling - 0/3 nodes available: Insufficient memory
kubectl describe nodes | grep -A8 'Allocated resources'
```

**Checklist de Pending:** recursos insuficientes → taints sem toleration →
nodeSelector/affinity sem match → PVC não vinculado → limite de pods por node.

## Cenário 4 — Running mas não Ready

```bash
kubectl -n lab-pods get pod probe-errada           # READY 0/1, STATUS Running
kubectl -n lab-pods describe pod probe-errada | grep -A3 Events
kubectl get endpoints -n lab-pods                  # <<< pod NAO aparece aqui
```

**Ponto de ouro:** pod não-Ready é **removido dos Endpoints do Service**. É a
ponte entre o lab de pods e o de rede — mencione isso e você conecta os dois temas.

- **readinessProbe** falha → sai do balanceamento (não reinicia).
- **livenessProbe** falha → **reinicia o container**.
- **startupProbe** → protege apps de boot lento; enquanto ela não passa, as
  outras duas ficam suspensas. É a solução do Cenário 6.

## Cenário 5 — ImagePullBackOff

```bash
kubectl -n lab-pods describe pod image-inexistente | grep -A5 Events
```
Causas: tag inexistente · registry privado sem `imagePullSecret` · rate limit do
Docker Hub · sem rota até o registry.

## Cenário 6 — Liveness agressiva

```bash
kubectl -n lab-pods get pod liveness-agressiva -w   # RESTARTS subindo
```
**Correção:** `startupProbe` com `failureThreshold: 30, periodSeconds: 2`
(60s de carência), mantendo a liveness rápida depois que o app subiu.

---

## Comandos de varredura (bons para abrir a resposta)

```bash
# Pods problematicos em todo o cluster
kubectl get pods -A --field-selector=status.phase!=Running

# Top ofensores por restart (o exercicio de coding automatiza isto)
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' \
  -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount \
  | tail -10

# Eventos recentes ordenados (eventos caducam em ~1h!)
kubectl get events -A --sort-by='.metadata.creationTimestamp' | tail -25

# Consumo real (precisa metrics-server)
kubectl top pods -A --sort-by=memory
```
